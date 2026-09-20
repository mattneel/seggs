const std = @import("std");
const c = @import("native");
const Client = @import("acp/client.zig").Client;
const files = @import("platform/files.zig");

fn require(condition: bool) !void {
    if (!condition) return error.AcpSmokeFailed;
}

fn contains(bytes: []const u8, needle: []const u8) bool {
    if (needle.len > bytes.len) return false;
    for (0..bytes.len - needle.len + 1) |start| {
        if (std.mem.eql(u8, bytes[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn pump(clients: []Client) !void {
    for (clients) |*client| {
        client.pump();
        if (client.state == .failed) {
            std.log.err("{s}: {s}", .{ client.preset.id, client.last_error orelse "unknown failure" });
            return error.AcpClientFailed;
        }
    }
    c.SDL_Delay(2);
}

fn ready(clients: []const Client) bool {
    for (clients) |client| if (client.state != .ready) return false;
    return true;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2) {
        if (std.mem.eql(u8, args[1], "--omp")) return liveAgent(init, "omp", "Oh-My-Pi", &.{ "omp", "acp" });
        if (std.mem.eql(u8, args[1], "--claude")) return liveAgent(init, "claude", "Claude Code", &.{"claude-agent-acp"});
        if (std.mem.eql(u8, args[1], "--codex")) return liveAgent(init, "codex", "Codex", &.{"codex-acp"});
    }
    if (args.len != 3) return error.ExpectedPythonAndMockScript;
    c.SDL_SetMainReady();
    if (!c.SDL_Init(0)) return error.SdlInit;
    defer c.SDL_Quit();
    const a = init.gpa;
    const cwd = try std.process.currentPathAlloc(init.io, a);
    defer a.free(cwd);
    const alpha = [_][]const u8{ args[1], args[2], "--name", "alpha", "--fragment", "3" };
    const beta = [_][]const u8{ args[1], args[2], "--name", "beta", "--fragment", "5" };
    const gamma = [_][]const u8{ args[1], args[2], "--name", "gamma", "--fragment", "7" };
    var clients = [_]Client{
        Client.init(a, .{ .id = "alpha", .name = "Alpha", .argv = &alpha }, cwd),
        Client.init(a, .{ .id = "beta", .name = "Beta", .argv = &beta }, cwd),
        Client.init(a, .{ .id = "gamma", .name = "Gamma", .argv = &gamma }, cwd),
    };
    defer for (&clients) |*client| client.deinit();
    for (&clients) |*client| try client.start();
    const deadline = c.SDL_GetTicks() + 15_000;
    while (!ready(&clients)) {
        try require(c.SDL_GetTicks() < deadline);
        try pump(&clients);
    }
    try require(!std.mem.eql(u8, clients[0].session_id.?, clients[1].session_id.?));
    try require(!std.mem.eql(u8, clients[1].session_id.?, clients[2].session_id.?));
    try clients[0].prompt("permission alpha-token");
    try clients[1].prompt("slow beta-token");
    try clients[2].prompt("gamma-token / \"escaped\" / \xce\xbb");
    var rejected = false;
    var cancelled = false;
    while (!ready(&clients)) {
        try require(c.SDL_GetTicks() < deadline);
        try pump(&clients);
        if (!rejected and clients[0].permission != null) {
            try clients[0].answerPermission(false);
            rejected = true;
        }
        if (!cancelled and contains(clients[1].transcript.items, "mock[")) {
            try clients[1].cancel();
            cancelled = true;
        }
    }
    try require(rejected and cancelled);
    try require(contains(clients[0].transcript.items, "permission=rejected"));
    try require(contains(clients[1].transcript.items, "[Stop: cancelled]"));
    try require(contains(clients[2].transcript.items, "mock[gamma]"));
    try require(!contains(clients[2].transcript.items, "alpha-token"));
    try require(!contains(clients[0].transcript.items, "gamma-token"));
    for (&clients) |client| try require(client.completed_turns == 1);
    try require(clients[0].tool_events >= 2);
    try clients[0].prompt("second alpha turn");
    while (!ready(&clients)) {
        try require(c.SDL_GetTicks() < deadline);
        try pump(&clients);
    }
    try require(clients[0].completed_turns == 2);
    std.log.info("PASS: three native ACP transports, stream isolation, permission rejection, cancellation, and session reuse", .{});

    // Early exit: a process that terminates without completing the handshake
    // must transition the lane to FAILED instead of hanging on the deadline.
    const dead = [_][]const u8{ args[1], "-c", "import sys; sys.exit(7)" };
    var dead_client = Client.init(a, .{ .id = "dead", .name = "Dead", .argv = &dead }, cwd);
    defer dead_client.deinit();
    try dead_client.start();
    const dead_deadline = c.SDL_GetTicks() + 15_000;
    while (dead_client.state != .failed) {
        try require(c.SDL_GetTicks() < dead_deadline);
        dead_client.pump();
        c.SDL_Delay(2);
    }
    const reason = dead_client.last_error orelse return error.MissingFailureReason;
    try require(std.mem.indexOf(u8, reason, "eof") != null);
    std.log.info("PASS: early agent exit transitions the lane to FAILED", .{});

    // fs capability: a client reads the mock script through fs/read_text_file.
    const fs_prompt_text = try std.fmt.allocPrint(a, "fsread {s}", .{args[2]});
    defer a.free(fs_prompt_text);
    const fs_argv = [_][]const u8{ args[1], args[2], "--name", "fs", "--fragment", "3" };
    var fs_client = Client.init(a, .{ .id = "fs", .name = "Fs", .argv = &fs_argv }, cwd);
    defer fs_client.deinit();
    try fs_client.start();
    const fs_deadline = c.SDL_GetTicks() + 15_000;
    while (fs_client.state != .ready) {
        try require(c.SDL_GetTicks() < fs_deadline);
        fs_client.pump();
        c.SDL_Delay(2);
    }
    try fs_client.prompt(fs_prompt_text);
    while (fs_client.state != .ready) {
        try require(c.SDL_GetTicks() < fs_deadline);
        fs_client.pump();
        c.SDL_Delay(2);
    }
    try require(contains(fs_client.transcript.items, "fs-read-ok"));
    std.log.info("PASS: fs/read_text_file returns file content through the capability broker", .{});

    const write_path = "/tmp/seggs-smoke-write.txt";
    const write_prompt_text = try std.fmt.allocPrint(a, "fswrite {s}|written-by-smoke", .{write_path});
    defer a.free(write_prompt_text);
    try fs_client.prompt(write_prompt_text);
    while (fs_client.state != .ready) {
        try require(c.SDL_GetTicks() < fs_deadline);
        fs_client.pump();
        c.SDL_Delay(2);
    }
    try require(contains(fs_client.transcript.items, "fs-write-ok"));
    const written = try files.read(a, write_path, 1024 * 1024);
    defer a.free(written);
    try require(std.mem.eql(u8, written, "written-by-smoke"));
    _ = c.SDL_RemovePath(write_path);
    std.log.info("PASS: fs/write_text_file writes file content through the capability broker", .{});

    // Terminal capability: the client owns the process, its bounded output, and
    // its lifetime; the agent only holds an id.
    try fs_client.prompt("terminal");
    while (fs_client.state != .ready) {
        try require(c.SDL_GetTicks() < fs_deadline);
        fs_client.pump();
        c.SDL_Delay(2);
    }
    try require(contains(fs_client.transcript.items, "terminal-ok"));
    std.log.info("PASS: terminal/create runs an isolated command, reports its exit, and releases it", .{});

    // Session config: cycle the mode option through session/set_config_option.
    try fs_client.cycleConfigOption("mode");
    while (!contains(fs_client.transcript.items, "[Config updated]")) {
        try require(c.SDL_GetTicks() < fs_deadline);
        fs_client.pump();
        c.SDL_Delay(2);
    }
    try require(std.mem.eql(u8, fs_client.configValue("mode").?, "plan"));
    std.log.info("PASS: session/set_config_option updates the session config", .{});
}

/// Opt-in live-agent gate: a real ACP turn through the Seggs client.
/// Requires the agent on PATH and its credentials. Not part of `verify`.
fn liveAgent(init: std.process.Init, id: []const u8, name: []const u8, argv: []const []const u8) !void {
    const a = init.gpa;
    c.SDL_SetMainReady();
    if (!c.SDL_Init(0)) return error.SdlInit;
    defer c.SDL_Quit();
    const cwd = try std.process.currentPathAlloc(init.io, a);
    defer a.free(cwd);
    var client = Client.init(a, .{ .id = id, .name = name, .argv = argv }, cwd);
    defer client.deinit();
    try client.start();
    const deadline = c.SDL_GetTicks() + 120_000;
    while (client.state != .ready) {
        try require(c.SDL_GetTicks() < deadline);
        client.pump();
        c.SDL_Delay(2);
    }
    try client.prompt("Reply with exactly the word PONG");
    while (client.state != .ready) {
        try require(c.SDL_GetTicks() < deadline);
        client.pump();
        c.SDL_Delay(2);
    }
    try require(client.completed_turns == 1);
    // A completed turn alone would also accept an agent that answered with an
    // error frame, so require the word the prompt asked for.
    try require(contains(client.transcript.items, "PONG"));
    std.log.info("PASS: live {s} ACP turn completed ({d} transcript bytes)", .{ name, client.transcript.items.len });
}
