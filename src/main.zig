const std = @import("std");
const builtin = @import("builtin");
const c = @import("native");
const App = @import("app.zig").App;
const Renderer = @import("gpu/renderer.zig").Renderer;
const Host = @import("ext/host.zig").Host;
const registry = @import("agents/registry.zig");
const files = @import("platform/files.zig");

const help =
    \\Seggs 0.2.0 — GPU editor and concurrent ACP client
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
    var screenshot_arg: ?[]const u8 = null;
    var exercise_window = false;
    var exercise_ime = false;
    var exercise_click = false;
    var window_width: c_int = 1440;
    var window_height: c_int = 900;
    var fullscreen_override: ?bool = null;
    var frames_limit: ?usize = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}\n", .{help});
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("Seggs 0.2.0 / Zig 0.17.0 / ACP v1 / SeggsC extensions\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--windowed")) {
            fullscreen_override = false;
        } else if (std.mem.eql(u8, arg, "--fullscreen")) {
            fullscreen_override = true;
        } else if (std.mem.eql(u8, arg, "--exercise-window")) {
            exercise_window = true;
        } else if (std.mem.eql(u8, arg, "--exercise-ime")) {
            exercise_ime = true;
        } else if (std.mem.eql(u8, arg, "--exercise-click")) {
            exercise_click = true;
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
            } else if (std.mem.eql(u8, arg, "--window-size")) {
                var parts = std.mem.splitScalar(u8, value, 'x');
                window_width = std.fmt.parseInt(c_int, parts.next() orelse "1440", 10) catch return error.BadWindowSize;
                window_height = std.fmt.parseInt(c_int, parts.next() orelse "900", 10) catch return error.BadWindowSize;
            } else if (std.mem.eql(u8, arg, "--screenshot")) {
                screenshot_arg = value;
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
    std.log.info("config: {d} agent(s), {d} lsp arg(s)", .{ config.agents.len, config.lsp.len });
    const font = try findFont(arena, font_arg);
    const font_z = try arena.dupeSentinel(u8, font, 0);
    c.SDL_SetMainReady();
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
    defer c.SDL_Quit();
    if (!c.TTF_Init()) return error.TtfInit;
    defer c.TTF_Quit();
    const flags: c.SDL_WindowFlags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | (if (config.fullscreen) @as(c.SDL_WindowFlags, c.SDL_WINDOW_FULLSCREEN) else 0);
    const window = c.SDL_CreateWindow("Seggs", window_width, window_height, flags) orelse return error.WindowCreate;
    defer c.SDL_DestroyWindow(window);
    _ = c.SDL_SetWindowMinimumSize(window, 640, 420);
    _ = c.SDL_StartTextInput(window);
    defer _ = c.SDL_StopTextInput(window);
    var renderer = try Renderer.init(a, window, font_z.ptr);
    defer renderer.deinit();
    // The primary face covers one script family; anything else, such as CJK or
    // emoji, is drawn from a fallback face when the system has one.
    for (try findFallbackFonts(arena)) |path| {
        const path_z = try arena.dupeSentinel(u8, path, 0);
        renderer.addFallbackFont(path_z.ptr) catch |err| {
            std.log.warn("fallback font {s}: {s}", .{ path, @errorName(err) });
        };
    }
    std.log.info("fallbacks: {d} registered", .{renderer.fallbackFontCount()});
    std.log.info("atlas: advance {d:.2}, line height {d:.2}", .{ renderer.atlas.advance, renderer.atlas.line_height });
    var app = try App.init(a, window, config, root);
    defer app.deinit();
    var host = Host.init(a);
    defer host.deinit();
    app.attachHost(&host);
    const extension_dir = try std.fs.path.join(arena, &.{ root, "extensions", "dist" });
    const loaded = host.loadExtensions(extension_dir);
    var extension_stamp: ?files.FileStamp = files.dirStamp(a, extension_dir, ".js") catch null;
    writeExtensionReport(a, root, &host);
    if (host.firstProblem()) |failure| {
        // A bundle that does not parse is said out loud, not only logged: an
        // author or an agent has to be able to see that the editor rejected it.
        app.status("extension {s} failed: {s}", .{ failure.name, failure.problem });
        std.log.info("extensions: {d} loaded", .{loaded});
    } else if (loaded > 0) {
        app.status("{s}", .{host.status()});
        std.log.info("extensions: {d} loaded; status: {s}", .{ loaded, host.status() });
    } else {
        std.log.info("extensions: none loaded from {s}", .{extension_dir});
    }
    if (file_arg) |path| {
        const resolved = try std.fs.path.resolve(arena, &.{ root, path });
        try app.openFile(resolved);
    }
    var frame_arena = std.heap.ArenaAllocator.init(a);
    defer frame_arena.deinit();
    var frames: usize = 0;
    var last_extension_check: u64 = c.SDL_GetTicks();
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
        if (exercise_window) try exerciseWindow(window, frames);
        // An extension bundle that changes is reloaded, so an author or an agent
        // can write one and see the result without restarting the editor. The
        // report is rewritten either way, so a failed load is readable.
        const now = c.SDL_GetTicks();
        if (now -| last_extension_check > 500) {
            last_extension_check = now;
            const current: ?files.FileStamp = files.dirStamp(a, extension_dir, ".js") catch null;
            const changed = if (extension_stamp) |previous|
                (current == null or !previous.eql(current.?))
            else
                current != null;
            if (changed) {
                extension_stamp = current;
                const reloaded = host.loadExtensions(extension_dir);
                std.log.info("extensions reloaded: {d} loaded", .{reloaded});
                if (host.firstProblem()) |failure| {
                    app.status("extension {s} failed: {s}", .{ failure.name, failure.problem });
                }
            }
            writeExtensionReport(a, root, &host);
        }
        if (exercise_ime) exerciseIme(&app, frames);
        if (exercise_click) exerciseClick(&app, frames);
        if (frames_limit) |limit| if (frames >= limit) break;
    }
    if (screenshot_arg) |path| {
        try renderer.capture(path);
        std.log.info("screenshot: {s}", .{path});
    }
    std.log.info("atlas: {d} glyphs packed, {d} placeholder hits", .{ renderer.atlas.glyphCount(), renderer.atlas.missing });
}

/// Drive the window through the transitions the GPU gate names, so a headless
/// run exercises them instead of only the steady state. Each step reports what
/// the environment accepted: a window manager is not always present, and a
/// refusal is recorded rather than treated as a rendering failure.
/// Drive the IME path through real events, so a run exercises composition
/// instead of only committed text. The composition is pushed so that the state
/// it produces is reported on the following frame, and a second composition is
/// left active for the capture.
fn exerciseIme(app: *App, frame: usize) void {
    switch (frame) {
        2 => pushEditing("nihongo", 2, 3),
        3 => {
            const span = app.preedit.selectionCells();
            std.log.info("ime: composition {d} cell(s), selection {d}..{d}", .{ app.preedit.cellCount(), span.start, span.start + span.len });
        },
        4 => {
            g_ime_document_before = app.workspace.activeDocument().buffer.len();
            pushInput("nihongo");
        },
        5 => std.log.info("ime: committed, document {d} -> {d} byte(s)", .{ g_ime_document_before, app.workspace.activeDocument().buffer.len() }),
        6 => pushEditing("kana", 1, 2),
        7 => {
            const span = app.preedit.selectionCells();
            std.log.info("ime: composition {d} cell(s), selection {d}..{d}", .{ app.preedit.cellCount(), span.start, span.start + span.len });
        },
        else => {},
    }
}

/// Write what the extension host knows to a file inside the workspace, so an
/// author — or an agent writing an extension — can read why a bundle failed
/// without watching the editor's stderr.
fn writeExtensionReport(a: std.mem.Allocator, root: []const u8, host: *Host) void {
    const json = host.diagnostics(a) catch return;
    defer a.free(json);
    const dir = std.fs.path.join(a, &.{ root, ".seggs" }) catch return;
    defer a.free(dir);
    const dir_z = a.dupeSentinel(u8, dir, 0) catch return;
    defer a.free(dir_z);
    _ = c.SDL_CreateDirectory(dir_z.ptr);
    const path = std.fs.path.join(a, &.{ dir, "extensions.json" }) catch return;
    defer a.free(path);
    files.replace(a, path, json) catch |err| {
        std.log.warn("extension report not written: {s}", .{@errorName(err)});
    };
}

/// Click the first panel an extension drew, so the round trip from an interface
/// event to an extension handler is exercised rather than assumed.
fn exerciseClick(app: *App, frame: usize) void {
    switch (frame) {
        6 => {
            const point = app.panelPoint("transcript") orelse {
                std.log.warn("click: no transcript panel was drawn", .{});
                return;
            };
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            ev.button.button = c.SDL_BUTTON_LEFT;
            ev.button.clicks = 1;
            ev.button.x = point.x;
            ev.button.y = point.y;
            if (!c.SDL_PushEvent(&ev)) std.log.warn("click not delivered: {s}", .{c.SDL_GetError()});
        },
        7 => std.log.info("click: status is now {s}", .{app.message_()}),
        8 => pushKey(c.SDLK_TAB),
        9 => pushKey(c.SDLK_RETURN),
        11 => std.log.info("click: activate status is now {s}", .{app.message_()}),
        12 => {
            // Opening a file from the explorer: the request travels from the
            // panel to the editor and back as a status message.
            const point = app.panelFocusPoint("explorer") orelse {
                std.log.warn("open: no explorer row was focusable", .{});
                return;
            };
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            ev.button.button = c.SDL_BUTTON_LEFT;
            ev.button.clicks = 1;
            ev.button.x = point.x;
            ev.button.y = point.y;
            if (!c.SDL_PushEvent(&ev)) std.log.warn("open click not delivered: {s}", .{c.SDL_GetError()});
        },
        14 => std.log.info("open: status is now {s}", .{app.message_()}),
        18 => {
            // The rail is the region every width keeps, so clicking it is what a
            // narrow window can still do.
            const point = app.panelFocusPoint("activity") orelse {
                std.log.warn("rail: no rail entry was drawn", .{});
                return;
            };
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            ev.button.button = c.SDL_BUTTON_LEFT;
            ev.button.clicks = 1;
            ev.button.x = point.x;
            ev.button.y = point.y;
            if (!c.SDL_PushEvent(&ev)) std.log.warn("rail click not delivered: {s}", .{c.SDL_GetError()});
        },
        16 => {
            // Moving the pointer onto a row has to reach the panel that drew it.
            const point = app.hoverPoint("explorer") orelse {
                std.log.warn("hover: no explorer row was drawn", .{});
                return;
            };
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_MOUSE_MOTION;
            ev.motion.x = point.x;
            ev.motion.y = point.y;
            if (!c.SDL_PushEvent(&ev)) std.log.warn("hover not delivered: {s}", .{c.SDL_GetError()});
        },
        15 => {
            // And a lane row, whose handler asks the editor for an agent action
            // rather than an editor one.
            const point = app.panelFocusPoint("lanes") orelse {
                std.log.warn("lanes: no lane was focusable", .{});
                return;
            };
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            ev.button.button = c.SDL_BUTTON_LEFT;
            ev.button.clicks = 1;
            ev.button.x = point.x;
            ev.button.y = point.y;
            if (!c.SDL_PushEvent(&ev)) std.log.warn("lane click not delivered: {s}", .{c.SDL_GetError()});
        },
        else => {},
    }
}

/// Deliver a key the way a keyboard would, so key routing is exercised through
/// the real event queue.
fn pushKey(keycode: c.SDL_Keycode) void {
    var ev = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_KEY_DOWN;
    ev.key.key = keycode;
    ev.key.mod = 0;
    if (!c.SDL_PushEvent(&ev)) std.log.warn("key not delivered: {s}", .{c.SDL_GetError()});
}

/// Document length before the exercise commits, reported on the next frame.
var g_ime_document_before: usize = 0;

fn pushEditing(text: [*c]const u8, start: c_int, length: c_int) void {
    var ev = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_TEXT_EDITING;
    ev.edit.text = text;
    ev.edit.start = start;
    ev.edit.length = length;
    if (!c.SDL_PushEvent(&ev)) std.log.warn("composition not delivered: {s}", .{c.SDL_GetError()});
}

fn pushInput(text: [*c]const u8) void {
    var ev = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_TEXT_INPUT;
    ev.text.text = text;
    if (!c.SDL_PushEvent(&ev)) std.log.warn("committed text not delivered: {s}", .{c.SDL_GetError()});
}

fn exerciseWindow(window: *c.SDL_Window, frame: usize) !void {
    switch (frame) {
        2 => {
            if (!c.SDL_SetWindowSize(window, 900, 640)) {
                std.log.warn("resize refused: {s}", .{c.SDL_GetError()});
            }
        },
        4 => {
            if (!c.SDL_MinimizeWindow(window)) std.log.warn("minimize refused: {s}", .{c.SDL_GetError()});
            if (!c.SDL_RestoreWindow(window)) std.log.warn("restore refused: {s}", .{c.SDL_GetError()});
        },
        6 => {
            if (!c.SDL_SetWindowFullscreen(window, true)) {
                std.log.warn("fullscreen refused: {s}", .{c.SDL_GetError()});
            } else if (!c.SDL_SetWindowFullscreen(window, false)) {
                std.log.warn("windowed restore refused: {s}", .{c.SDL_GetError()});
            }
        },
        else => return,
    }
    // A resize request settles asynchronously, so wait for the window before
    // reporting: otherwise the logged size is the one from before the request.
    if (!c.SDL_SyncWindow(window)) {
        std.log.warn("window did not settle: {s}", .{c.SDL_GetError()});
    }
    var logical_w: c_int = 0;
    var logical_h: c_int = 0;
    var pixel_w: c_int = 0;
    var pixel_h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &logical_w, &logical_h);
    _ = c.SDL_GetWindowSizeInPixels(window, &pixel_w, &pixel_h);
    std.log.info("window after step {d}: logical {d}x{d}, pixels {d}x{d}", .{ frame, logical_w, logical_h, pixel_w, pixel_h });
}

fn exists(a: std.mem.Allocator, path: []const u8) bool {
    const z = a.dupeSentinel(u8, path, 0) catch return false;
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

/// System faces that cover scripts the monospace primary face does not. Only
/// existing paths are returned; a missing set is not an error, unsupported
/// codepoints simply keep the placeholder.
fn findFallbackFonts(a: std.mem.Allocator) ![]const []const u8 {
    const candidates: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{
            "/System/Library/Fonts/PingFang.ttc",
            "/System/Library/Fonts/Hiragino Sans GB.ttc",
            "/System/Library/Fonts/Apple Color Emoji.ttc",
            "/Library/Fonts/Arial Unicode.ttf",
        },
        .windows => &.{
            "C:/Windows/Fonts/msgothic.ttc",
            "C:/Windows/Fonts/meiryo.ttc",
            "C:/Windows/Fonts/seguisym.ttf",
            "C:/Windows/Fonts/seguiemj.ttf",
        },
        else => &.{
            "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
            "/usr/share/fonts/truetype/fonts-japanese-gothic.ttf",
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        },
    };
    var found: std.ArrayList([]const u8) = .empty;
    for (candidates) |path| {
        if (exists(a, path)) try found.append(a, path);
    }
    return found.toOwnedSlice(a);
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
