const std = @import("std");
const builtin = @import("builtin");
const c = @import("native");
const App = @import("app.zig").App;
const Renderer = @import("gpu/renderer.zig").Renderer;
const registry = @import("agents/registry.zig");
const files = @import("platform/files.zig");

const help =
    \\Seggs 0.1.0 — GPU editor and concurrent ACP client
    \\Usage: seggs [--workspace PATH] [--file PATH] [--config PATH]
    \\             [--font PATH] [--windowed | --fullscreen] [--frames N]
    \\Defaults: current directory, fullscreen, no automatic agent launch.
    \\Config files execute programs. Only load a config that you trust.
    \\F5 starts the selected agent. Ctrl+L focuses the prompt.
    \\Ctrl+Enter sends to one agent. Ctrl+Shift+Enter sends to ready agents.
    \\F11 toggles fullscreen. Ctrl+P opens a file. Ctrl+Q quits.
;

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        std.log.err("Seggs: {s}. SDL: {s}", .{ @errorName(err), c.SDL_GetError() });
        return err;
    };
}

fn run(init: std.process.Init) !void {
    const a = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var workspace_arg: []const u8 = ".";
    var file_arg: ?[]const u8 = null;
    var config_arg: ?[]const u8 = null;
    var font_arg: ?[]const u8 = null;
    var fullscreen_override: ?bool = null;
    var frames_limit: ?usize = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}\n", .{help});
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("Seggs 0.1.0 / Zig 0.16.0 / ACP v1\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--windowed")) {
            fullscreen_override = false;
        } else if (std.mem.eql(u8, arg, "--fullscreen")) {
            fullscreen_override = true;
        } else {
            if (index + 1 >= args.len) return error.MissingArgument;
            index += 1;
            const value = args[index];
            if (std.mem.eql(u8, arg, "--workspace")) {
                workspace_arg = value;
            } else if (std.mem.eql(u8, arg, "--file")) {
                file_arg = value;
            } else if (std.mem.eql(u8, arg, "--config")) {
                config_arg = value;
            } else if (std.mem.eql(u8, arg, "--font")) {
                font_arg = value;
            } else if (std.mem.eql(u8, arg, "--frames")) {
                frames_limit = try std.fmt.parseInt(usize, value, 10);
                if (frames_limit.? == 0) return error.InvalidFrameCount;
            } else return error.UnknownArgument;
        }
    }
    const launch_cwd = try std.process.currentPathAlloc(init.io, a);
    defer a.free(launch_cwd);
    const root = try std.fs.path.resolve(a, &.{ launch_cwd, workspace_arg });
    defer a.free(root);
    var config: registry.Config = .{};
    var parsed_config: ?std.json.Parsed(registry.Config) = null;
    defer if (parsed_config) |*parsed| parsed.deinit();
    if (config_arg) |path| {
        const bytes = try files.read(a, path, 256 * 1024);
        defer a.free(bytes);
        parsed_config = try std.json.parseFromSlice(registry.Config, a, bytes, .{ .allocate = .alloc_always });
        config = parsed_config.?.value;
    } else {
        // The default mock stays valid when the workspace differs from launch_cwd.
        const presets = try arena.dupe(registry.Agent, &registry.builtins);
        const script = try findMock(arena, launch_cwd);
        presets[presets.len - 1].argv = try arena.dupe([]const u8, &.{ if (builtin.os.tag == .windows) "python" else "python3", script });
        config.agents = presets;
    }
    if (fullscreen_override) |value| config.fullscreen = value;
    try registry.validate(config);
    const font = try findFont(arena, font_arg);
    const font_z = try arena.dupeZ(u8, font);
    c.SDL_SetMainReady();
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
    defer c.SDL_Quit();
    if (!c.TTF_Init()) return error.TtfInit;
    defer c.TTF_Quit();
    const flags: c.SDL_WindowFlags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | (if (config.fullscreen) @as(c.SDL_WindowFlags, c.SDL_WINDOW_FULLSCREEN) else 0);
    const window = c.SDL_CreateWindow("Seggs", 1440, 900, flags) orelse return error.WindowCreate;
    defer c.SDL_DestroyWindow(window);
    _ = c.SDL_SetWindowMinimumSize(window, 900, 640);
    _ = c.SDL_StartTextInput(window);
    defer _ = c.SDL_StopTextInput(window);
    var renderer = try Renderer.init(a, window, font_z.ptr);
    defer renderer.deinit();
    var app = try App.init(a, window, config, root);
    defer app.deinit();
    if (file_arg) |path| {
        const resolved = try std.fs.path.resolve(arena, &.{ root, path });
        try app.openFile(resolved);
    }
    var frame_arena = std.heap.ArenaAllocator.init(a);
    defer frame_arena.deinit();
    var frames: usize = 0;
    while (app.running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) app.event(event) catch |err| app.status("{s}", .{@errorName(err)});
        if (!app.running) break;
        try app.update();
        var width: c_int = 0;
        var height: c_int = 0;
        if (!c.SDL_GetWindowSize(window, &width, &height)) return error.WindowSize;
        renderer.begin(@floatFromInt(@max(1, width)), @floatFromInt(@max(1, height)));
        _ = frame_arena.reset(.retain_capacity);
        try app.draw(&renderer, frame_arena.allocator());
        try renderer.present();
        frames += 1;
        if (frames_limit) |limit| if (frames >= limit) break;
    }
}

fn exists(a: std.mem.Allocator, path: []const u8) bool {
    const z = a.dupeZ(u8, path) catch return false;
    defer a.free(z);
    var info = std.mem.zeroes(c.SDL_PathInfo);
    return c.SDL_GetPathInfo(z.ptr, &info) and info.type == c.SDL_PATHTYPE_FILE;
}

fn findMock(a: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const local = try std.fs.path.join(a, &.{ cwd, "tools", "mock_agent.py" });
    if (exists(a, local)) return local;
    const base = c.SDL_GetBasePath();
    if (base != null) {
        const installed = try std.fs.path.resolve(a, &.{ std.mem.span(base), "..", "share", "seggs", "mock_agent.py" });
        if (exists(a, installed)) return installed;
    }
    // Other presets remain available even when the optional mock is absent.
    return local;
}

fn findFont(a: std.mem.Allocator, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |path| {
        if (!exists(a, path)) return error.FontNotFound;
        return path;
    }
    const candidates: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Monaco.ttf", "/Library/Fonts/Menlo.ttc" },
        .windows => &.{ "C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/cour.ttf" },
        else => &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/truetype/liberation2/LiberationMono-Regular.ttf", "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf" },
    };
    for (candidates) |path| if (exists(a, path)) return path;
    std.log.err("No system monospace font found. Use --font /absolute/path/to/font.ttf.", .{});
    return error.FontNotFound;
}
