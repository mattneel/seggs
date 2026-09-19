const std = @import("std");
const c = @import("native");
const Client = @import("acp/client.zig").Client;

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
}
