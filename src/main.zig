const std = @import("std");
const builtin = @import("builtin");
const c = @import("native");
const App = @import("app.zig").App;
const runs = @import("editor/runs.zig");
const Renderer = @import("gpu/renderer.zig").Renderer;
const Host = @import("ext/host.zig").Host;
const registry = @import("agents/registry.zig");
const files = @import("platform/files.zig");

const help =
    \\Seggs 0.2.0 — GPU editor and concurrent ACP client
    \\
    \\Usage: seggs [--workspace PATH] [--file PATH] [--config PATH]
    \\             [--theme PATH] [--font PATH] [--windowed | --fullscreen]
    \\             [--window-size WIDTHxHEIGHT] [--frames N]
    \\       seggs seggsc exec FILE.js
    \\
    \\Defaults: current directory, fullscreen, no automatic agent launch.
    \\Config files execute programs. Only load a config that you trust.
    \\F5 starts the selected agent. Ctrl+L focuses the prompt.
    \\Ctrl+Enter sends to that agent. Ctrl+Shift+Enter picks a destination.
    \\Ctrl+Shift+A opens an agent. F11 toggles fullscreen. Ctrl+Q quits.
    \\
    \\--version prints the version and exits. -h is a synonym for --help.
    \\
    \\QA flags, for looking at a frame with nobody in front of it:
    \\  --screenshot PATH  Write the last frame to PATH. The extension picks the
    \\                     format: .png, .bmp, .gif, .jpg, or .ppm.
    \\  --frames N         Stop after N frames, so a run ends without a window
    \\                     manager's help. The capture is of the last frame.
    \\  --exercise-NAME    Drive a path and leave it up for the capture. Each one
    \\                     reaches the state a person would rather than asserting
    \\                     it from the code. Names: window ime click terminal run
    \\                     compose tabs markdown transcript toolcalls records
    \\                     strips
    \\                     formula liveness themes embedded.
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
    // A subcommand is a word rather than a flag: `seggs seggsc exec <file>`
    // runs one SeggsC file and exits without opening a window. It is here
    // because the engine the editor embeds is not a `qjs` from a package
    // manager, and an author testing a bundle needs the engine that ships.
    if (args.len > 1 and std.mem.eql(u8, args[1], "seggsc")) return runSeggsC(init, args[2..]);
    var workspace_arg: []const u8 = ".";
    var file_arg: ?[]const u8 = null;
    var config_arg: ?[]const u8 = null;
    var font_arg: ?[]const u8 = null;
    var theme_arg: ?[]const u8 = null;
    var screenshot_arg: ?[]const u8 = null;
    var exercise_window = false;
    var exercise_ime = false;
    var exercise_click = false;
    var exercise_terminal = false;
    var exercise_run = false;
    var exercise_compose = false;
    var exercise_tabs = false;
    var exercise_markdown = false;
    var exercise_transcript = false;
    var exercise_toolcalls = false;
    var exercise_records = false;
    var exercise_formula = false;
    var exercise_liveness = false;
    var exercise_themes = false;
    var exercise_embedded = false;
    var exercise_strips = false;
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
        } else if (std.mem.eql(u8, arg, "--exercise-terminal")) {
            exercise_terminal = true;
        } else if (std.mem.eql(u8, arg, "--exercise-run")) {
            exercise_run = true;
        } else if (std.mem.eql(u8, arg, "--exercise-compose")) {
            exercise_compose = true;
        } else if (std.mem.eql(u8, arg, "--exercise-tabs")) {
            exercise_tabs = true;
        } else if (std.mem.eql(u8, arg, "--exercise-markdown")) {
            exercise_markdown = true;
        } else if (std.mem.eql(u8, arg, "--exercise-transcript")) {
            exercise_transcript = true;
        } else if (std.mem.eql(u8, arg, "--exercise-toolcalls")) {
            exercise_toolcalls = true;
        } else if (std.mem.eql(u8, arg, "--exercise-records")) {
            exercise_records = true;
        } else if (std.mem.eql(u8, arg, "--exercise-formula")) {
            exercise_formula = true;
        } else if (std.mem.eql(u8, arg, "--exercise-liveness")) {
            exercise_liveness = true;
        } else if (std.mem.eql(u8, arg, "--exercise-themes")) {
            exercise_themes = true;
        } else if (std.mem.eql(u8, arg, "--exercise-strips")) {
            exercise_strips = true;
        } else if (std.mem.eql(u8, arg, "--exercise-embedded")) {
            exercise_embedded = true;
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
            } else if (std.mem.eql(u8, arg, "--theme")) {
                theme_arg = value;
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
    // Pixels per point. The face is rasterised at this density and the layout
    // is measured in device pixels, so a denser display is sharper rather than
    // smaller.
    const scale = c.SDL_GetWindowDisplayScale(window);
    var renderer = try Renderer.init(a, window, font_z.ptr, scale);
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
    var app = try App.init(a, init.io, window, config, root);
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
    if (theme_arg) |path| {
        // Loading a theme is not fatal: an editor that refuses to start because
        // a colour file has a typo in it is worse than one that starts in its
        // own palette and says what went wrong.
        const resolved = try std.fs.path.resolve(arena, &.{ root, path });
        app.loadTheme(resolved) catch |err| {
            app.status("theme {s}: {s}", .{ path, @errorName(err) });
            std.log.err("theme {s}: {s}", .{ resolved, @errorName(err) });
        };
    }
    if (file_arg) |path| {
        const resolved = try std.fs.path.resolve(arena, &.{ root, path });
        try app.openFile(resolved);
    }
    // A stall is two pictures of one lane: the frame while it works and the
    // frame after it has gone quiet. The run's own `--screenshot` is the second
    // one, so the first is written beside it - two frames of one run rather than
    // two runs of a stopwatch.
    var liveness_working_shot: ?[]const u8 = null;
    if (exercise_liveness) {
        if (screenshot_arg) |path| liveness_working_shot = try std.fmt.allocPrint(arena, "{s}.working", .{path});
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
        // The drawable is in device pixels, which is what the GPU draws into
        // and what every measurement here is expressed in.
        if (!c.SDL_GetWindowSizeInPixels(window, &width, &height)) return error.WindowSize;
        app.scale = c.SDL_GetWindowDisplayScale(window);
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
        if (exercise_terminal) exerciseTerminal(&app, frames, frame_arena.allocator());
        if (exercise_run) exerciseRun(&app, frames, frame_arena.allocator());
        if (exercise_compose) exerciseCompose(&app, frames);
        if (exercise_tabs) exerciseTabs(&app, frames);
        if (exercise_markdown) exerciseMarkdown(&app, frames);
        if (exercise_transcript) exerciseTranscript(&app, frames);
        if (exercise_toolcalls) exerciseToolCalls(&app, frames);
        if (exercise_records) exerciseRecords(&app, frames);
        if (exercise_formula) exerciseFormula(&app, frames);
        if (exercise_liveness) exerciseLiveness(&app, frames, &renderer, init.io, a, liveness_working_shot);
        if (exercise_themes) app.exerciseThemes(frames);
        if (exercise_embedded) exerciseEmbedded(&app, frames);
        if (exercise_strips) exerciseStrips(&app, frames);
        if (frames_limit) |limit| if (frames >= limit) break;
    }
    if (screenshot_arg) |path| {
        try renderer.capture(init.io, a, path);
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
/// Prove the terminal end to end: the dock starts a real shell, the editor
/// types a command into it, and the shell's answer comes back through the
/// A shell answers when it answers, so the screen is polled from the frame the
/// command is typed until the answer is there: a fixed frame would make this
/// pass or fail on how fast the machine running it is.
const terminal_first_read = 120;
const terminal_last_read = 480;

var terminal_answered = false;
var run_reported = false;
var fixture_step_sent = false;
var approval_sent = false;
var approval_held: usize = 0;
var review_proposed = false;
var review_reported = false;
var review_held: usize = 0;
var pipe_sent = false;

/// A shell answers when it answers, so the screen is polled from the frame the
/// command is typed until the answer is there: a fixed frame would make this
/// pass or fail on how fast the machine running it is.
/// Fill a strip past its width, so the scrolling can be looked at rather than
/// asserted. The dock's tabs were never bounded, so it is the one that can be
/// filled from an exercise without a config that names more agents than the
/// default four; the lane strip uses the same range maths and comes into view
/// the same way.
fn exerciseStrips(app: *App, frame: usize) void {
    switch (frame) {
        6 => app.toggleTerminal() catch {},
        else => {},
    }
    if (frame < 90 or strips_open) return;
    strips_open = true;
    // One shell started many times over: the point is the strip, not the
    // programs. The last tab is the active one, so the strip has to have
    // scrolled for the capture to show it whole - which is the behaviour, and
    // the reason the exercise exists.
    for (0..10) |_| app.newTerminalTab("/bin/sh") catch |err| {
        std.log.err("strips: {s}", .{@errorName(err)});
        return;
    };
    // And every configured lane, so a config naming more agents than the strip
    // can show scrolls the other strip too. With the default four there is
    // nothing to scroll, which is correct and looks like nothing happening.
    for (0..app.clients.len) |index| {
        app.active = index;
        app.startAgent() catch |err| std.log.err("strips: lane {d}: {s}", .{ index, @errorName(err) });
    }
}

var strips_open = false;

fn exerciseTerminal(app: *App, frame: usize, a: std.mem.Allocator) void {
    switch (frame) {
        6 => app.toggleTerminal() catch {},
        else => {},
    }
    if (frame < 90) return;
    if (frame == 90) {
        // The styled lines are what the screen grab measures: printf expands
        // the escapes the shell is handed, so the emulator sees real SGR.
        // More lines than the screen holds, so the dock has history for the
        // scrollbar to place the viewport in, then the styled lines.
        app.terminalInput("for i in $(seq 1 30); do echo history-$i; done; printf 'seggs-terminal\\nplain\\n\\033[1mbold\\033[0m\\n\\033[3mitalic\\033[0m\\n'\r") catch {};
        return;
    }
    if (terminal_answered or frame < terminal_first_read) return;
    const screen = app.terminalScreen(a) catch null;
    const text = screen orelse {
        std.log.err("terminal: no screen to read", .{});
        return;
    };
    defer a.free(text);
    // The echoed command can wrap across rows and split any word in it, so the
    // proof is a string only running the command can produce: the loop's last
    // line, whose text the command line spells differently.
    // The shell was asked to mark its own commands, so the terminal should know
    // which one printed this, and the fixture checks that rather than assuming
    // it: a marker that never arrived reads as a screen of text.
    // The shell was asked to mark its own commands. Whether it did is the
    // difference between a terminal result that knows what produced it and a
    // screen of text, so the fixture reports which one it got.
    if (app.terminalCommand(a) catch null) |command| {
        defer a.free(command);
        const trimmed = std.mem.trim(u8, command, " \r\n");
        std.log.info("terminal: the shell marked its command: {s}", .{trimmed});
    } else {
        std.log.info("terminal: this shell reports no command boundaries; the screen is what it is", .{});
    }
    const answered = std.mem.indexOf(u8, text, "history-30") != null;
    const printed = std.mem.indexOf(u8, text, "seggs-terminal") != null;
    if (answered and printed) {
        terminal_answered = true;
        std.log.info("PASS: the shell answered on the terminal screen", .{});
    } else if (frame >= terminal_last_read) {
        std.log.err("terminal screen never answered: answered={} printed={}", .{ answered, printed });
    }
}

/// A run starts from what is on screen, and its steps are the report: this
/// exercise starts one and reports what it produced.
fn exerciseRun(app: *App, frame: usize, a: std.mem.Allocator) void {
    switch (frame) {
        6 => {
            app.startRun() catch |err| std.log.err("run: {s}", .{@errorName(err)});
            // And a run whose step a harness can actually answer, so the
            // round trip is exercised rather than described.
            const mock = app.agentIndex("Local mock") orelse {
                std.log.err("run: no local mock profile", .{});
                return;
            };
            app.active = mock;
            app.startAgent() catch |err| std.log.err("run: mock {s}", .{@errorName(err)});
        },
        8 => {
            // The starter workflow is described before the fixture replaces it,
            // so both the shape of a workflow and the round trip are reported.
            if (app.activeRun()) |starter| {
                const current = starter.current();
                std.log.info("run {s}: {d} steps, {d} artifacts, current={s}", .{
                    starter.name,
                    starter.steps.len,
                    starter.artifacts.items.len,
                    if (current) |step| step.name else "none",
                });
            }
        },

        else => {},
    }
    // A change is proposed while the run is still working: a review that only
    // exists after everything finishes is not one anybody reads.
    if (!review_proposed and frame >= 9) {
        review_proposed = true;
        const document = app.workspace.activeDocument();
        app.review.propose(.{
            .path = app.workspace.activePath() orelse "",
            .expected_revision = document.revision,
            .start_byte = 0,
            .end_byte = 0,
            .replacement = "// accepted through the review surface\n",
        }) catch |err| std.log.err("review: {s}", .{@errorName(err)});
        app.perspective = .review;
    }

    // The harness has to be up before a step can be sent to it, and its answer
    // arrives when it arrives: both are polled for rather than assumed, so this
    // does not depend on how fast a machine starts a process.
    if (!fixture_step_sent and frame >= 10) {
        if (app.agentReady(app.active)) {
            const steps = [_]runs.Step{
                .{ .name = "ask", .produces = .plan, .action = .{ .agent = .{ .harness = app.active, .request = "Say hello" } } },
                .{ .name = "git --version", .produces = .checks, .action = .{ .command = &.{ "git", "--version" } } },
                // A person decides before anything downstream runs: the gate is
                // what separates a workflow's progress from its acceptance.
                .{ .name = "approve", .produces = .review, .action = .approval },
            };
            var fixture = runs.Run.init(app.allocator, "fixture", &steps) catch |err| {
                std.log.err("run: fixture {s}", .{@errorName(err)});
                return;
            };
            app.runs.append(app.allocator, fixture) catch |err| {
                fixture.deinit();
                std.log.err("run: fixture {s}", .{@errorName(err)});
                return;
            };
            app.run_index = app.runs.items.len - 1;
            fixture_step_sent = true;
            app.runStep() catch |err| std.log.err("run: step {s}", .{@errorName(err)});
        } else if (frame > 200) {
            std.log.err("run: no harness was ready to take a step", .{});
            return;
        }
    }

    // The run is driven one step at a time, and each step is sent when the one
    // before it is no longer running: a pipeline that fired everything at once
    // would not be a pipeline.
    if (fixture_step_sent and !run_reported) {
        if (app.activeRun()) |active| {
            if (active.current()) |step| {
                if (step.state == .waiting) {
                    app.runStep() catch |err| std.log.err("run: step {s}", .{@errorName(err)});
                }
            }
        }
        // The person in the fixture presses the key a person would press,
        // rather than calling the approval directly: the binding is part of
        // what has to work.
        // A person does not answer in the frame the question is asked, and the
        // inbox is only visible while the question stands: the fixture waits
        // long enough for that to be true.
        if (app.runWaiting() and !approval_sent) {
            approval_held += 1;
            if (approval_held < 90) return;
            approval_sent = true;
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_KEY_DOWN;
            ev.key.key = c.SDLK_A;
            ev.key.mod = c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT;
            if (!c.SDL_PushEvent(&ev)) std.log.err("run: approval key not delivered", .{});
        }
    }

    // Every step has to have produced something: an agent's answer, a command's
    // output with its exit status, and a person's decision.
    if (fixture_step_sent and !run_reported) {
        const active = app.activeRun() orelse return;
        if (active.artifacts.items.len < 3) {
            if (frame > 400) std.log.err("run {s}: {d} steps, no answer recorded", .{ active.name, active.steps.len });
            return;
        }
        run_reported = true;
        const answer = active.artifacts.items[active.artifacts.items.len - 1];
        var start: usize = 0;
        while (start < answer.body.len and (answer.body[start] == '\n' or answer.body[start] == '\r')) : (start += 1) {}
        var line: usize = start;
        while (line < answer.body.len and answer.body[line] != '\n' and answer.body[line] != '\r') : (line += 1) {}
        std.log.info("run {s}: {d} steps, {d} artifacts, {s} from {s}, {d} bytes: {s}", .{
            active.name,
            active.steps.len,
            active.artifacts.items.len,
            answer.kind.label(),
            answer.source,
            answer.body.len,
            answer.body[start..line],
        });
        return;
    }

    // A selection with nothing typed is a complete request, and it used to do
    // nothing at all: the harness answers it or the selection never left.
    if (run_reported and !pipe_sent) {
        pipe_sent = true;
        const mock = app.agentIndex("Local mock") orelse return;
        const before = app.agentTranscript(mock);
        const document = app.workspace.activeDocument();
        document.cursor = 8;
        app.selection_anchor = 0;
        app.pipeTo(mock) catch |err| std.log.err("pipe: {s}", .{@errorName(err)});
        std.log.info("pipe: selection sent with an empty prompt, transcript {d} -> {d}", .{ before, app.agentTranscript(mock) });
    }

    // The review is answered once the run it belongs to has reported: a change
    // is read while the work goes on and accepted when it is done.
    if (review_proposed and !review_reported) {
        if (app.review.count() > 0) {
            review_held += 1;
            if (review_held < 150) return;
            app.acceptReview() catch |err| std.log.err("review: {s}", .{@errorName(err)});
            return;
        }
        review_reported = true;
        const bytes = app.workspace.activeDocument().snapshot(a) catch return;
        defer a.free(bytes);
        const landed = std.mem.startsWith(u8, bytes, "// accepted through the review surface");
        std.log.info("review: {d} change(s) waiting, accepted={}", .{ app.review.count(), landed });
    }
}

/// The terminal's tabs: a strip a reader can add to, move around, and close.
var tabs_copied = false;

fn exerciseTabs(app: *App, frame: usize) void {
    switch (frame) {
        4 => app.toggleTerminal() catch |err| std.log.err("tabs: {s}", .{@errorName(err)}),
        8 => app.newTerminalTab(null) catch |err| std.log.err("tabs: {s}", .{@errorName(err)}),
        12 => app.newTerminalTab(null) catch |err| std.log.err("tabs: {s}", .{@errorName(err)}),
        16 => app.moveTerminalTab(false),
        20 => app.closeTerminalTab(),
        24 => app.shells.select(0),

        // `exit` in the shell is the one thing a reader types in a terminal
        // that means "I am done here", and the tab goes with it. The second
        // one leaves nothing behind, so the dock goes too.
        // More exits than there are shells: the count varies with what the
        // fixture opened above, and an exit typed at a shell that has already
        // gone lands on nothing.
        70, 74, 78, 82, 86 => if (app.activeShell()) |shell| shell.writeInput("exit\n") catch {},
        90 => std.log.info("tabs: after exit {d} shell(s) remain, dock is {s}", .{
            app.shells.count(),
            if (app.terminalOpen()) "up" else "down",
        }),
        28 => {
            // Toggling the view twice is a round trip: it puts the dock away
            // and brings it back. Anything that starts a shell here turns one
            // key into a row of tabs.
            const before = app.shells.count();
            app.toggleTerminal() catch |err| std.log.err("tabs: {s}", .{@errorName(err)});
            if (app.terminalOpen()) std.log.err("tabs: the dock stayed up", .{});
            app.toggleTerminal() catch |err| std.log.err("tabs: {s}", .{@errorName(err)});
            if (!app.terminalOpen()) std.log.err("tabs: the dock did not come back", .{});
            if (app.shells.count() != before) std.log.err("tabs: toggling started a shell", .{});
            std.log.info("tabs: toggle kept {d} shell(s) and the dock is {s}", .{ app.shells.count(), if (app.terminalOpen()) "up" else "down" });
        },
        50 => {
            // A drag over the screen, then the copy key: what a reader does with
            // a terminal's output before sending it somewhere.
            app.terminal_selection = .{ .anchor = .{ .x = 0, .y = 0 }, .cursor = .{ .x = 12, .y = 0 } };
        },
        51...61, 65...68 => {
            if (frame == 60) std.log.info("tabs: {d} open, showing {d} of {d}", .{
                app.shells.count(),
                app.shells.active + 1,
                app.shells.count(),
            });
            // A prompt arrives when the shell is ready rather than at a frame
            // number, and a shell that has printed nothing has nothing to copy.
            // So the copy is tried again each frame until it finds text, and the
            // line is reported when it does - which is what the gate reads.
            if (tabs_copied) return;
            if (std.mem.indexOf(u8, app.statusText(), "Copied") != null) {
                tabs_copied = true;
                std.log.info("tabs: copy reported {s}", .{app.statusText()});
                return;
            }
            app.copyTerminalSelection() catch |err| std.log.err("tabs: {s}", .{@errorName(err)});
        },
        69 => if (!tabs_copied) std.log.err("tabs: nothing was selected in the terminal", .{}),
        // The shell list: what this machine can run in a tab, rather than
        // whatever SHELL happens to name. It comes after the report at sixty,
        // so that report is still the arithmetic the move and the close left
        // rather than the count this tab adds to it.
        62 => pushKeyMod(c.SDLK_T, c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT),
        63 => pushKey(c.SDLK_RETURN),
        64 => std.log.info("tabs: shells: {s}", .{app.statusText()}),
        else => {},
    }
}

/// The Compose perspective: a run's steps as the sequence it will execute, with
/// what travels between them.
fn exerciseCompose(app: *App, frame: usize) void {
    switch (frame) {
        6 => app.startRun() catch |err| std.log.err("compose: {s}", .{@errorName(err)}),
        10 => app.perspective = .compose,
        24 => {
            const active = app.activeRun() orelse {
                std.log.err("compose: nothing to compose", .{});
                return;
            };
            var names: [128]u8 = undefined;
            var written: usize = 0;
            for (active.steps, 0..) |step, index| {
                if (index > 0 and written < names.len) {
                    const joiner = " | ";
                    @memcpy(names[written..][0..joiner.len], joiner);
                    written += joiner.len;
                }
                const take = @min(step.name.len, names.len - written);
                @memcpy(names[written..][0..take], step.name[0..take]);
                written += take;
            }
            std.log.info("compose {s}: {d} steps, {s}", .{ active.name, active.steps.len, names[0..written] });
        },
        else => {},
    }
}

/// The transcript as prose: a heading, a paragraph with inline runs, a list, a
/// quotation, a rule, a fenced code block, and a fenced diff. It is sent to the
/// mock harness, which echoes it back a few bytes at a time, so what the panel
/// draws is what came over the wire rather than bytes written into the
/// transcript by a fixture.
const markdown_sample =
    \\
    \\# Transcript, as markdown
    \\
    \\A table the panel has room for:
    \\
    \\| shape | field |
    \\| --- | --- |
    \\| read | path |
    \\| run | exit code |
    \\
    \\And one it has not, so it falls back to the source it was written in rather
    \\than shredding the columns across the dock:
    \\
    \\| first column long enough to overrun | second column long enough as well | third |
    \\| --- | --- | --- |
    \\| a cell | another cell | a third cell |
    \\
    \\Inline math such as $E = mc^2$ sits inside the sentence, and a display
    \\formula is set apart:
    \\
    \\$$
    \\\int_0^1 x^2 dx = \frac{1}{3}
    \\$$
    \\
    \\Prices are not formulas: $5 and $10 stay as they were written.
    \\
    \\A ~~struck word~~ is drawn with a rule through it, so a retraction is
    \\visible rather than merely quiet.
    \\
    \\See [the ACP specification](https://agentclientprotocol.com/) for what an
    \\agent is allowed to ask for.
    \\
    \\An agent's message with **bold**, *italic*, and `inline code`, wrapped at
    \\the panel's column rather than at the one the agent happened to choose.
    \\
    \\- a bullet, whose marker is not part of its words
    \\- a bullet long enough that the panel has to wrap it, so the continuation
    \\  line starts where the text above it does
    \\
    \\> a quotation, marked down its left edge
    \\
    \\---
    \\
    \\```zig
    \\// code takes the theme's scopes, as the editor's does
    \\const answer = 42;
    \\pub fn main() void {}
    \\```
    \\
    \\```diff
    \\--- a/src/app.zig
    \\+++ b/src/app.zig
    \\@@ -3101,7 +3101,8 @@
    \\         } else {
    \\             const bytes = if (client.transcript.items.len == 0) default_help else client.transcript.items;
    \\-            try wrappedTail(r, frame, run, bytes, self.transcript_scroll, theme.text);
    \\+            try self.drawTranscript(r, frame, run, bytes);
    \\         }
    \\```
;

/// Whether the sample has been sent, and whether the harness stopped echoing.
var markdown_sent = false;
var markdown_reported = false;

/// Put a markdown message in the transcript by having a harness say it: the
/// lane is started, the sample is sent as a prompt, and the frames after that
/// wait for the echo instead of assuming how fast a machine runs a mock.
fn exerciseMarkdown(app: *App, frame: usize) void {
    const mock = app.agentIndex("Local mock") orelse {
        std.log.err("markdown: no local mock profile", .{});
        return;
    };
    if (frame == 6) {
        app.active = mock;
        app.startAgent() catch |err| std.log.err("markdown: {s}", .{@errorName(err)});
        return;
    }
    if (!markdown_sent) {
        if (!app.agentReady(mock)) {
            if (frame > 400) std.log.err("markdown: the harness never came up", .{});
            return;
        }
        markdown_sent = true;
        app.prompt_text.clearRetainingCapacity();
        app.prompt_text.appendSlice(app.allocator, markdown_sample) catch |err| {
            std.log.err("markdown: {s}", .{@errorName(err)});
            return;
        };
        app.pipeTo(mock) catch |err| std.log.err("markdown: {s}", .{@errorName(err)});
        return;
    }
    if (markdown_reported) return;
    // The transcript is complete when the harness is idle again and the last
    // line of the sample is in it: an echo still arriving is not a transcript.
    const words = app.agentWords(mock);
    if (app.agentState(mock) == .ready and std.mem.indexOf(u8, words, "drawTranscript") != null) {
        markdown_reported = true;
        std.log.info("markdown: the harness echoed {d} bytes; the sample is in the transcript", .{words.len});
    } else if (frame > 600) {
        std.log.err("markdown: the echo never finished; {d} bytes so far", .{words.len});
    }
}

/// Whether the transcript panel has been asked the two things it can get wrong.
var transcript_scrolled = false;
var transcript_oversize = false;
var transcript_link_clicked = false;
var transcript_link_reported = false;
var transcript_census_reported = false;
var transcript_link_frame: usize = 0;

/// The transcript panel under strain, with no harness in the way: the markdown
/// sample is written straight into the lane's buffer with enough filler after
/// it to overflow the panel, then the wheel asks for more rows than there are,
/// and finally the transcript is made longer than the reader will take. Every
/// step is on a fixed frame, so the probe does not depend on how fast a harness
/// starts.
fn exerciseTranscript(app: *App, frame: usize) void {
    const mock = app.agentIndex("Local mock") orelse return;
    switch (frame) {
        6 => {
            app.active = mock;
            app.startAgent() catch |err| std.log.err("transcript: {s}", .{@errorName(err)});
            return;
        },
        8 => {
            const transcript = &app.clients[mock].transcript;
            transcript.clearRetainingCapacity();
            transcript.appendSlice(app.allocator, markdown_sample) catch return;
            for (0..40) |index| {
                var line: [64]u8 = undefined;
                const filler = std.fmt.bufPrint(&line, "\n- filler line {d}\n", .{index}) catch return;
                transcript.appendSlice(app.allocator, filler) catch return;
            }
            return;
        },
        else => {},
    }
    if (!transcript_scrolled and frame >= 20 and app.agentsOpen()) {
        transcript_scrolled = true;
        var ev = std.mem.zeroes(c.SDL_Event);
        ev.type = c.SDL_EVENT_MOUSE_WHEEL;
        // Sixty notches is a hundred and eighty rows, which is more than the
        // transcript has: the panel has to stop at its first row rather than
        // count past it into empty surface.
        ev.wheel.y = 60;
        ev.wheel.mouse_x = app.geometry.agents.x + app.geometry.agents.w / 2;
        ev.wheel.mouse_y = app.geometry.agents.y + app.geometry.agents.h / 2;
        if (!c.SDL_PushEvent(&ev)) std.log.err("transcript: the wheel event was not delivered", .{});
        return;
    }
    if (transcript_scrolled and !transcript_oversize and frame >= 30) {
        transcript_oversize = true;
        std.log.info("transcript: the wheel asked for 180 rows; the panel stopped at {d} of {d}", .{ app.transcript_scroll, app.transcript_max_scroll });
        return;
    }
    // The link is clicked on whichever frame it is first drawable rather than
    // on a fixed one. The panel is drawn only once the lane is up, and how many
    // frames that takes depends on the machine: a harness that clicks on a
    // schedule is a harness that fails when the runner is busy. This is the
    // shape the scroll step above already uses - retry without claiming to have
    // acted - and the deadline is what keeps a missing link a reported failure
    // rather than a hang.
    if (!transcript_link_clicked and frame >= 30 and frame <= 37) {
        if (app.linkPoint()) |point| {
            transcript_link_clicked = true;
            transcript_link_frame = frame;
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            ev.button.button = c.SDL_BUTTON_LEFT;
            ev.button.x = point.x;
            ev.button.y = point.y;
            if (!c.SDL_PushEvent(&ev)) std.log.err("transcript: the link click was not delivered", .{});
        } else if (frame == 37) {
            std.log.err("transcript: no link was drawn to click", .{});
        }
        return;
    }
    if (transcript_link_clicked and !transcript_link_reported and frame >= transcript_link_frame + 1) {
        transcript_link_reported = true;
        std.log.info("transcript: a click on a link says: {s}", .{app.statusText()});
    }
    if (transcript_link_reported and !transcript_census_reported and frame >= transcript_link_frame + 2) {
        transcript_census_reported = true;
        var census: [256]u8 = undefined;
        std.log.info("transcript: blocks drawn: {s}", .{app.transcriptCensus(&census)});
    }
    if (transcript_oversize and frame == 40) {
        // Past the reader's bound, so the panel has to fall back to the plain
        // wrapped text it drew before markdown, and say so, rather than draw
        // nothing or take the frame down with it.
        const bytes = app.allocator.alloc(u8, (1 << 20) + 1) catch return;
        defer app.allocator.free(bytes);
        @memset(bytes, 'x');
        const transcript = &app.clients[mock].transcript;
        transcript.clearRetainingCapacity();
        transcript.appendSlice(app.allocator, bytes) catch |err| std.log.err("transcript: {s}", .{@errorName(err)});
        return;
    }
    if (transcript_oversize and frame == 60) {
        std.log.info("transcript: an oversize transcript says: {s}", .{app.statusText()});
    }
}

/// Whether the call turn has been sent, reported, and clicked.
var calls_sent = false;
var calls_drawn = false;
var calls_clicked = false;
var call_reported = false;
var call_open_before = false;
var call_chip_clicked = false;
var call_chip_reported = false;
var call_open_before_chip = false;

/// The frame the click on a call happens on. It is late enough that a run which
/// stops before it captures the chips closed, which is what makes the click's
/// effect a difference in pixels rather than a claim.
const call_click_frame: usize = 100;

/// `seggs seggsc <verb> [args]` - the extension host driven from a shell.
///
/// One verb so far, and it is the one an author needs: run a file and print what
/// it reported. A window is never opened, which is the point - testing a bundle
/// should not need a display, and a measurement taken under a running editor is
/// a measurement of the editor as much as of the bundle.
fn runSeggsC(init: std.process.Init, rest: []const []const u8) !void {
    const a = init.gpa;
    if (rest.len == 0 or std.mem.eql(u8, rest[0], "help")) {
        std.debug.print("usage: seggs seggsc exec <file.js>\n", .{});
        return;
    }
    if (!std.mem.eql(u8, rest[0], "exec")) {
        std.debug.print("seggsc: unknown verb '{s}'\nusage: seggs seggsc exec <file.js>\n", .{rest[0]});
        return error.UnknownArgument;
    }
    if (rest.len < 2) {
        std.debug.print("seggsc exec: no file named\nusage: seggs seggsc exec <file.js>\n", .{});
        return error.MissingArgument;
    }
    var host = Host.init(a);
    defer host.deinit();
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(a);
    const ok = host.runFile(rest[1], &report) catch |err| {
        std.debug.print("seggsc: {s}: {s}\n", .{ rest[1], @errorName(err) });
        return err;
    };
    // The report is what the file said, printed as it said it, so a caller
    // piping this into a script gets the line and nothing around it.
    std.debug.print("{s}\n", .{report.items});
    // A file that did not run has to be distinguishable from one that ran and
    // said nothing, which is the whole reason a shell checks an exit code: a
    // test that failed silently is worse than one that failed loudly.
    if (!ok) std.process.exit(1);
}

/// Whether an embedded terminal has been reported.
var embedded_sent = false;
var embedded_reported = false;

/// A turn whose tool call embeds a terminal: the agent creates one through the
/// client, announces a call that names it, waits for it, and then releases it.
///
/// What this is here to prove is the second half of the protocol's sentence -
/// the output keeps being displayed after the terminal is released. The report
/// is taken *after* the release has been answered, so a count above zero at that
/// point is a screen the editor kept rather than a record the client still had.
const embedded_report_frame: usize = 150;

fn exerciseEmbedded(app: *App, frame: usize) void {
    const mock = app.agentIndex("Local mock") orelse return;
    if (frame == 6) {
        app.active = mock;
        app.startAgent() catch |err| std.log.err("embedded: {s}", .{@errorName(err)});
        return;
    }
    if (!embedded_sent) {
        if (!app.agentReady(mock)) {
            if (frame > 400) std.log.err("embedded: the harness never came up", .{});
            return;
        }
        embedded_sent = true;
        app.prompt_text.clearRetainingCapacity();
        app.prompt_text.appendSlice(app.allocator, "terminal: run something in a terminal") catch |err| {
            std.log.err("embedded: {s}", .{@errorName(err)});
            return;
        };
        app.pipeTo(mock) catch |err| std.log.err("embedded: {s}", .{@errorName(err)});
        return;
    }
    if (!embedded_reported and frame >= embedded_report_frame) {
        embedded_reported = true;
        // The chip as well as the count, because a terminal drawn under nothing
        // is not what the protocol asks for: the call is what says which command
        // ran in it.
        const summary = app.agentToolCalls(mock, app.allocator) catch null;
        defer if (summary) |text| app.allocator.free(text);
        std.log.info("embedded: {d} terminal(s) drawn after the agent released it; calls: {s}", .{
            app.embeddedTerminalsDrawn(),
            summary orelse "none",
        });
    }
}

/// A transcript of tool calls, drawn as the chips a reader scans.
///
/// The turn is the one the fixture's `tools` prefix answers with: a read that
/// finished, an edit carrying a diff, a command that failed, and a command still
/// running, which is the four states a chip colours. The report names what each
/// chip shows, and the click opens the edit rather than describing it, so the
/// surface a reader uses is exercised instead of only drawn.
fn exerciseToolCalls(app: *App, frame: usize) void {
    const mock = app.agentIndex("Local mock") orelse {
        std.log.err("calls: no local mock profile", .{});
        return;
    };
    if (frame == 6) {
        app.active = mock;
        app.startAgent() catch |err| std.log.err("calls: {s}", .{@errorName(err)});
        return;
    }
    if (!calls_sent) {
        if (!app.agentReady(mock)) {
            if (frame > 400) std.log.err("calls: the harness never came up", .{});
            return;
        }
        calls_sent = true;
        app.prompt_text.clearRetainingCapacity();
        app.prompt_text.appendSlice(app.allocator, "tools: show what a call looks like") catch |err| {
            std.log.err("calls: {s}", .{@errorName(err)});
            return;
        };
        app.pipeTo(mock) catch |err| std.log.err("calls: {s}", .{@errorName(err)});
        return;
    }
    if (!calls_drawn) {
        // The turn is done when the harness is idle again and every call it
        // sent has arrived: a chip still on the wire is not one to report.
        if (app.agentState(mock) != .ready) {
            if (frame > 600) std.log.err("calls: the harness never finished the turn", .{});
            return;
        }
        if (app.agentCallCount(mock) < 4) {
            if (frame > 600) std.log.err("calls: the turn produced {d} tool call(s)", .{app.agentCallCount(mock)});
            return;
        }
        const summary = app.agentToolCalls(mock, app.allocator) catch return;
        defer app.allocator.free(summary);
        calls_drawn = true;
        std.log.info("calls: {d} drawn, {s}", .{ app.agentCallCount(mock), summary });
        return;
    }
    if (!calls_clicked) {
        if (frame < call_click_frame) return;
        calls_clicked = true;
        call_open_before = app.callIsExpanded(mock, "mock-edit");
        // The click lands on the card's **last** row rather than on its chip.
        // The card is shut here, so that row is the marker - the line saying how
        // many lines were withheld - and the point of the marker is that it is
        // what asks for them. A click is delivered the way SDL delivers one, so
        // what moves the card is the interface's own routing rather than a call
        // into it.
        const point = app.callMarkerPoint("mock-edit") orelse {
            std.log.err("calls: the edit's last row was not drawn, so the click had nothing to land on", .{});
            return;
        };
        var ev = std.mem.zeroes(c.SDL_Event);
        ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        ev.button.button = c.SDL_BUTTON_LEFT;
        ev.button.clicks = 1;
        ev.button.x = point.x;
        ev.button.y = point.y;
        if (!c.SDL_PushEvent(&ev)) std.log.warn("calls: the click was not delivered", .{});
        return;
    }
    if (!call_reported and frame >= call_click_frame + 2) {
        call_reported = true;
        std.log.info("calls: the click on the edit changed open {s} -> {s}", .{
            openWord(call_open_before),
            openWord(app.callIsExpanded(mock, "mock-edit")),
        });
    }
    if (call_reported and !call_chip_clicked and frame >= call_click_frame + 4) {
        call_chip_clicked = true;
        call_open_before_chip = app.callIsExpanded(mock, "mock-edit");
        // The other end: the chip itself, on a card that is now open, has to
        // close it. Both halves are the same routing, so a card that opens and
        // will not close is a card whose hit covers the wrong rows.
        const point = app.toolCallPoint("mock-edit") orelse {
            std.log.err("calls: the edit's chip was not drawn, so the click had nothing to land on", .{});
            return;
        };
        var ev = std.mem.zeroes(c.SDL_Event);
        ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        ev.button.button = c.SDL_BUTTON_LEFT;
        ev.button.clicks = 1;
        ev.button.x = point.x;
        ev.button.y = point.y;
        if (!c.SDL_PushEvent(&ev)) std.log.warn("calls: the chip click was not delivered", .{});
        return;
    }
    if (call_chip_clicked and !call_chip_reported and frame >= call_click_frame + 6) {
        call_chip_reported = true;
        std.log.info("calls: the click on the edit changed open {s} -> {s}", .{
            openWord(call_open_before_chip),
            openWord(app.callIsExpanded(mock, "mock-edit")),
        });
    }
}

/// Whether a call is open, as the report words it.
fn openWord(open: bool) []const u8 {
    return if (open) "true" else "false";
}

/// Whether the records turn has been sent, caught arriving, reported, and
/// clicked.
var records_sent = false;
var records_pulsed = false;
var records_drawn = false;
var records_clicked = false;
var records_reported = false;
var record_open_before = false;

/// The frame the click on a run happens on, for the same reason the calls'
/// click is late: what the click changes has to be a difference rather than a
/// claim about the frame it arrived in.
const record_click_frame: usize = 160;

/// A turn of reasoning, a plan, usage, a compaction and a mode, drawn as the
/// records a reader meets them as.
///
/// The turn is the one the fixture's `records` prefix answers with, and the
/// report names every record the drawing half reads rather than the pixels it
/// became: a chip that says `thinking ● 54 B` here is a chip that says it on
/// screen. The click opens the reasoning, which is the one thing in the
/// transcript a reader most needs to be able to do and the easiest to get
/// wrong, because a run has no agent id to be keyed by - it is keyed by the
/// handle the client gave it.
/// Show display mathematics in a transcript and leave it up for the capture.
///
/// The formula path runs from the markdown parser through the TeX engine to the
/// renderer, and every one of those can be right while the reader still sees
/// backslashes: the parser has to recognise the form the agent wrote, the
/// typesetter has to lay it out, and the row has to claim the height it draws
/// over. Only looking at the panel says whether all three happened.
fn exerciseFormula(app: *App, frame: usize) void {
    const mock = app.agentIndex("Local mock") orelse {
        std.log.err("formula: no local mock profile", .{});
        return;
    };
    if (frame == 6) {
        app.active = mock;
        app.startAgent() catch |err| std.log.err("formula: {s}", .{@errorName(err)});
        return;
    }
    if (formula_sent) return;
    if (!app.agentReady(mock)) return;
    formula_sent = true;
    app.prompt_text.clearRetainingCapacity();
    app.prompt_text.appendSlice(app.allocator, "math: show me some mathematics") catch |err| {
        std.log.err("formula: {s}", .{@errorName(err)});
        return;
    };
    app.pipeTo(mock) catch |err| std.log.err("formula: {s}", .{@errorName(err)});
}

var formula_sent = false;

fn exerciseRecords(app: *App, frame: usize) void {
    const mock = app.agentIndex("Local mock") orelse {
        std.log.err("records: no local mock profile", .{});
        return;
    };
    if (frame == 6) {
        app.active = mock;
        app.startAgent() catch |err| std.log.err("records: {s}", .{@errorName(err)});
        return;
    }
    if (!records_sent) {
        if (!app.agentReady(mock)) {
            if (frame > 400) std.log.err("records: the harness never came up", .{});
            return;
        }
        records_sent = true;
        app.prompt_text.clearRetainingCapacity();
        app.prompt_text.appendSlice(app.allocator, "records: show what a session is doing") catch |err| {
            std.log.err("records: {s}", .{@errorName(err)});
            return;
        };
        app.pipeTo(mock) catch |err| std.log.err("records: {s}", .{@errorName(err)});
        return;
    }
    if (!records_pulsed) {
        // The report is taken the moment a run is caught still arriving, rather
        // than at a frame chosen in advance: what is being checked is that a
        // reader can see the agent is working, and a frame picked by number
        // would be checking the fixture's arithmetic instead.
        if (app.agentStreamCount(mock) == 0 or !app.streamIsStreaming(mock, 0)) {
            if (app.agentState(mock) == .ready and frame > 400) {
                std.log.err("records: no run was caught arriving, so the pulse was never drawn", .{});
            }
            return;
        }
        records_pulsed = true;
        const live = app.agentRecords(mock, app.allocator) catch return;
        defer app.allocator.free(live);
        std.log.info("records: mid-turn {s}", .{live});
        return;
    }
    if (!records_drawn) {
        // The turn is done when the harness is idle and every run it sent has
        // arrived: a run still on the wire is not one to report.
        if (app.agentState(mock) != .ready) {
            if (frame > 600) std.log.err("records: the harness never finished the turn", .{});
            return;
        }
        if (app.agentStreamCount(mock) < 3) {
            if (frame > 600) std.log.err("records: the turn produced {d} run(s)", .{app.agentStreamCount(mock)});
            return;
        }
        const summary = app.agentRecords(mock, app.allocator) catch return;
        defer app.allocator.free(summary);
        records_drawn = true;
        std.log.info("records: {d} runs drawn, {s}", .{ app.agentStreamCount(mock), summary });
        return;
    }
    if (!records_clicked) {
        if (frame < record_click_frame) return;
        records_clicked = true;
        // The reasoning is the first run of the turn, which is the one placed
        // before the answer rather than after it.
        record_open_before = app.streamIsOpen(mock, 0);
        const point = app.streamPoint(mock, 0) orelse {
            std.log.err("records: the reasoning's line was not drawn, so the click had nothing to land on", .{});
            return;
        };
        var ev = std.mem.zeroes(c.SDL_Event);
        ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        ev.button.button = c.SDL_BUTTON_LEFT;
        ev.button.clicks = 1;
        ev.button.x = point.x;
        ev.button.y = point.y;
        if (!c.SDL_PushEvent(&ev)) std.log.warn("records: the click was not delivered", .{});
        return;
    }
    if (!records_reported and frame >= record_click_frame + 2) {
        records_reported = true;
        const after = app.agentRecords(mock, app.allocator) catch return;
        defer app.allocator.free(after);
        std.log.info("records: the click on the reasoning changed open {s} -> {s}", .{
            openWord(record_open_before),
            openWord(app.streamIsOpen(mock, 0)),
        });
        std.log.info("records: open {s}", .{after});
    }
}

/// The two readings a reader has to be able to tell apart: a lane that is
/// working and a lane that has gone quiet mid-turn.
///
/// The turn is real - the prompt goes over the wire to the mock harness - and so
/// is the silence: the harness's `quiet` prompt names the calls it is making and
/// then never answers at all, which is what a harness that is thinking, or hung,
/// looks like from this side of the pipe. The reading is taken through the call
/// the dock draws its line with, at each moment, so a line reported here is a
/// line that was on screen; the run then ends with the stalled reading on
/// screen, which is what the run's own `--screenshot` holds.
var liveness_sent = false;
var liveness_working = false;
var liveness_named = false;
var liveness_stalled = false;
var liveness_started: u64 = 0;
/// The phase the fixture last saw and how many frames in a row it has held.
var liveness_phase: u8 = 0;
var liveness_held: usize = 0;

/// How many frames in a row a phase is held before the fixture believes it. The
/// reading is taken after the frame has been drawn, so a phase that has only
/// just begun is a frame ahead of the pixels on screen - exactly where the two
/// thresholds sit - and a few frames of it are waited out first, which is what
/// makes the picture that follows a picture of this phase rather than the one
/// before it.
const liveness_settled_frames: usize = 4;

/// How long the fixture waits for the whole reading before giving up and saying
/// so. The stall itself takes `activity.stall_after_ms` of real silence; this is
/// the backstop that keeps a broken run from being a run that hangs.
const liveness_deadline_ms: u64 = 60_000;

fn exerciseLiveness(app: *App, frame: usize, renderer: *Renderer, io: std.Io, a: std.mem.Allocator, working_shot: ?[]const u8) void {
    if (liveness_started == 0) liveness_started = App.now();
    if (liveness_stalled) return;
    const mock = app.agentIndex("Local mock") orelse {
        std.log.err("liveness: no local mock profile", .{});
        app.running = false;
        return;
    };
    switch (frame) {
        6 => {
            app.active = mock;
            app.startAgent() catch |err| std.log.err("liveness: {s}", .{@errorName(err)});
            return;
        },
        else => {},
    }
    if (!liveness_sent) {
        if (!app.agentReady(mock)) {
            if (frame > 600) {
                std.log.err("liveness: the harness never came up", .{});
                app.running = false;
            }
            return;
        }
        liveness_sent = true;
        app.prompt_text.clearRetainingCapacity();
        app.prompt_text.appendSlice(app.allocator, "quiet") catch |err| {
            std.log.err("liveness: {s}", .{@errorName(err)});
            return;
        };
        app.pipeTo(mock) catch |err| std.log.err("liveness: {s}", .{@errorName(err)});
        return;
    }
    // The dock's own reading, fitted to the dock's own width: what is logged
    // here is what a reader would see.
    var line: [256]u8 = undefined;
    const reading = app.activityLine(mock, &line, app.geometry.agents.w);
    const phase: u8 = @backingInt(reading.phase);
    if (phase != liveness_phase) {
        liveness_phase = phase;
        liveness_held = 0;
    }
    liveness_held += 1;
    if (liveness_held < liveness_settled_frames) return;
    switch (reading.phase) {
        // The turn is in flight and the harness has been quiet for less than the
        // stall threshold, which is what a reader sees while an agent thinks.
        .working => if (!liveness_working) {
            liveness_working = true;
            std.log.info("liveness: working reading: \"{s}\" indicator \"{s}\" after {d}ms", .{
                reading.line, reading.indicator, App.now() -| liveness_started,
            });
            if (working_shot) |path| renderer.capture(io, a, path) catch |err| std.log.err("liveness: {s}", .{@errorName(err)});
        } else if (!liveness_named and app.agentCallCount(mock) > 0) {
            // The harness has said what it is on, and the line names it: the
            // subject is the latest call's, which is what a reader watching an
            // agent work wants to know.
            liveness_named = true;
            std.log.info("liveness: named reading: \"{s}\" indicator \"{s}\" after {d}ms", .{
                reading.line, reading.indicator, App.now() -| liveness_started,
            });
        },
        // The same turn past the threshold: nothing has arrived and the line
        // says so. The run stops here, so the frame the screenshot holds is this
        // one.
        .stalled => {
            liveness_stalled = true;
            std.log.info("liveness: stalled reading: \"{s}\" indicator \"{s}\" after {d}ms", .{
                reading.line, reading.indicator, App.now() -| liveness_started,
            });
            app.running = false;
        },
        else => {},
    }
    if (!liveness_stalled and App.now() -| liveness_started > liveness_deadline_ms) {
        std.log.err("liveness: the turn never read as stalled; the dock still says \"{s}\"", .{reading.line});
        app.running = false;
    }
}

/// What the agent strip reported: the lane a tab click moved the interface to,
/// so the frame that says what the click did can name the same lane.
var tab_clicked = false;
var tab_name: []const u8 = "";

/// Whether the dock's own controls are part of this run at all. They are when a
/// lane is running in a window with room for the dock; a window too narrow for
/// columns drops the dock, and that run is a different check. Where the dock
/// cannot be clicked the fixture says so in a line the gate reads, rather than
/// leaving the steps it could not take looking like steps that passed.
var dock_clickable = false;

/// Whether the panel click was actually pushed, so the frames that report what
/// it did only report it when it happened.
var panel_clicked = false;

fn exerciseClick(app: *App, frame: usize) void {
    switch (frame) {
        12 => {
            // Opening a file from the explorer: the request travels from the
            // panel to the editor and back as a status message.
            // The navigator is native, so the fixture clicks a row of the tree
            // rather than a panel an extension used to draw there.
            const row = app.explorerFirstFileRow() orelse {
                std.log.err("click: FAIL - no explorer row was drawn, so the click had nothing to land on", .{});
                return;
            };
            const point = app.explorerRowPoint(row) orelse {
                std.log.err("click: FAIL - that explorer row is not on screen", .{});
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
        // A lane has to be running before anything the dock draws is clicked:
        // the dock is on screen exactly while something is running in it, and a
        // lane nobody has started is offered by the list of templates rather
        // than drawn as a tab. The list opens from the keyboard, which is what
        // a reader with a collapsed dock has.
        15 => pushKeyMod(c.SDLK_A, c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT),
        16 => {
            pushInput("mock");
            // Moving the pointer onto a row has to reach the panel that drew
            // it. The navigator is native now, so the pointer is moved over a
            // panel an extension still draws: the check is that a panel takes
            // events, and the tab strip is one.
            const point = app.hoverPoint("tabs") orelse {
                std.log.err("click: FAIL - the editor's tab strip was not drawn, so the pointer had nowhere to move", .{});
                return;
            };
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_MOUSE_MOTION;
            ev.motion.x = point.x;
            ev.motion.y = point.y;
            if (!c.SDL_PushEvent(&ev)) std.log.warn("hover not delivered: {s}", .{c.SDL_GetError()});
        },
        17 => pushKey(c.SDLK_RETURN),
        18 => {
            // The rail is the region every width keeps, so clicking it is what a
            // narrow window can still do.
            const point = app.panelFocusPoint("activity") orelse {
                std.log.err("click: FAIL - the activity rail was not drawn, so the click had nothing to land on", .{});
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
        19 => {
            // The frame the lane has had to come up by. Everything below that
            // aims at the dock is inside it, so this is the frame that says
            // whether there is a dock to aim at, and which of the two reasons
            // there is not.
            dock_clickable = app.agentsOpen() and app.geometry.agents.w > 0;
            if (dock_clickable) {
                std.log.info("agents: {s} is {s} and the dock is up", .{ app.agentName(app.active), app.agentState(app.active).label() });
            } else if (app.agentsOpen()) {
                std.log.warn("click: skipped - this window has no room for the agent dock, so its controls are not part of this run", .{});
            } else {
                std.log.err("click: FAIL - no lane came up, so the dock stayed collapsed and none of its controls were drawn", .{});
            }
        },
        20 => {
            if (!dock_clickable) return;
            // Both ways in, and the same list either way. The `+` at the end of
            // the strip opens the templates as a dropdown under itself; the
            // filter line and the rows are the same rows the key opens.
            const point = app.agentPlusPoint() orelse {
                std.log.err("click: FAIL - the control that opens a lane was not drawn, so the click had nothing to land on", .{});
                return;
            };
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            ev.button.button = c.SDL_BUTTON_LEFT;
            ev.button.clicks = 1;
            ev.button.x = point.x;
            ev.button.y = point.y;
            if (!c.SDL_PushEvent(&ev)) std.log.warn("templates click not delivered: {s}", .{c.SDL_GetError()});
        },
        21 => pushInput("mock"),
        22 => pushKey(c.SDLK_RETURN),
        23 => std.log.info("agents: jump list: {s}", .{app.statusText()}),
        24 => {
            // And the key that opens the same rows over the window instead of
            // under the control.
            pushKeyMod(c.SDLK_A, c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT);
        },
        25 => pushInput("mock"),
        26 => pushKey(c.SDLK_RETURN),
        27 => std.log.info("agents: jump key: {s}", .{app.statusText()}),
        // The run area belongs to the extension until the lane the dock is
        // showing has said something, and after that it is that lane's own
        // record. A lane that was never started is one that has said nothing,
        // so the interface is moved onto one before the panel is clicked: that
        // is the state the panel is on screen in, and Ctrl+1..8 picks a lane by
        // number.
        28 => pushKeyMod(c.SDLK_1, c.SDL_KMOD_CTRL),
        29 => {
            if (!dock_clickable) return;
            const point = app.panelPoint("transcript") orelse {
                std.log.err("click: FAIL - the transcript panel was not drawn, so the click had nothing to land on", .{});
                return;
            };
            panel_clicked = true;
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            ev.button.button = c.SDL_BUTTON_LEFT;
            ev.button.clicks = 1;
            ev.button.x = point.x;
            ev.button.y = point.y;
            if (!c.SDL_PushEvent(&ev)) std.log.warn("click not delivered: {s}", .{c.SDL_GetError()});
        },
        30 => {
            if (!panel_clicked) return;
            std.log.info("click: status is now {s}", .{app.message_()});
            pushKey(c.SDLK_TAB);
        },
        31 => if (panel_clicked) pushKey(c.SDLK_RETURN),
        32 => {
            if (!panel_clicked) return;
            std.log.info("click: activate status is now {s}", .{app.message_()});
            // The strip is the dock's navigation: a click on a lane's tab makes
            // that lane the one the interface works on. The interface was moved
            // off that lane at frame twenty-eight, so the click is visible in
            // what the frame after it says the interface is on rather than
            // taken on faith.
            const mock = app.agentIndex("Local mock") orelse {
                std.log.err("click: FAIL - this session has no Local mock lane to click", .{});
                return;
            };
            // The strip lists the lanes that are running, so the lane's tab is
            // at its position among those rather than at its position in the
            // registry.
            var position: usize = 0;
            for (0..mock) |index| {
                if (app.agentState(index).up()) position += 1;
            }
            const point = app.agentTabPoint(position) orelse {
                std.log.err("click: FAIL - no lane tab fits in a dock {d:.0} pixels wide, so the click had nothing to land on", .{app.geometry.agents.w});
                return;
            };
            tab_clicked = true;
            tab_name = app.agentName(mock);
            var ev = std.mem.zeroes(c.SDL_Event);
            ev.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            ev.button.button = c.SDL_BUTTON_LEFT;
            ev.button.clicks = 1;
            ev.button.x = point.x;
            ev.button.y = point.y;
            if (!c.SDL_PushEvent(&ev)) std.log.warn("tab click not delivered: {s}", .{c.SDL_GetError()});
        },
        33 => {
            if (!tab_clicked) return;
            std.log.info("agent tab: clicked {s}, now on {s}", .{ tab_name, app.agentName(app.active) });
        },
        34 => {
            // And the destination list, with something to send: a request that
            // is a selection does not need words, and the lane started at frame
            // seventeen has had the frames since to finish its handshake.
            app.workspace.activeDocument().cursor = 8;
            app.selection_anchor = 0;
            pushKeyMod(c.SDLK_RETURN, c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT);
        },
        35 => pushKey(c.SDLK_RETURN),
        36 => {
            std.log.info("agents: send to: {s}", .{app.statusText()});
            // Ctrl+W closes what has focus, and the dock is what has it: the
            // lane goes the way its own tab's box closes it.
            pushKeyMod(c.SDLK_W, c.SDL_KMOD_CTRL);
        },
        37 => {
            std.log.info("agents: close: {s}", .{app.statusText()});
            pushKey(c.SDLK_ESCAPE);
        },
        38 => pushKeyMod(c.SDLK_W, c.SDL_KMOD_CTRL),
        39 => std.log.info("agents: close buffer: {s}", .{app.statusText()}),
        else => {},
    }
}

/// Deliver a key the way a keyboard would, so key routing is exercised through
/// the real event queue.
fn pushKey(keycode: c.SDL_Keycode) void {
    pushKeyMod(keycode, 0);
}

/// The same, with the modifiers a binding is only itself with.
fn pushKeyMod(keycode: c.SDL_Keycode, mod: c.SDL_Keymod) void {
    var ev = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_KEY_DOWN;
    ev.key.key = keycode;
    ev.key.mod = mod;
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
    // The scale is what makes the two sizes differ, so a run at a scale other
    // than one is the only evidence that a high-density window is exercised.
    std.log.info("window after step {d}: logical {d}x{d}, pixels {d}x{d}, scale {d:.2}", .{
        frame,
        logical_w,
        logical_h,
        pixel_w,
        pixel_h,
        c.SDL_GetWindowDisplayScale(window),
    });
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
