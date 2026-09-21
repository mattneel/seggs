const std = @import("std");

pub const Agent = struct {
    id: []const u8,
    name: []const u8,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// The ACP authentication method to use for this agent. Empty means the
    /// client does not authenticate on its own, and a harness that needs a
    /// login reports the methods it offers instead.
    auth: ?[]const u8 = null,
};

pub const Config = struct {
    fullscreen: bool = true,
    agents: []const Agent = &builtins,
    /// Opt-in transcript persistence. Off by default for privacy.
    persist_transcripts: bool = false,
    /// Optional language server command. No server runs when this is empty.
    lsp: []const []const u8 = &.{},
};

pub const builtins = [_]Agent{
    .{ .id = "omp", .name = "Oh-My-Pi", .argv = &.{ "omp", "acp" } },
    .{ .id = "codex", .name = "Codex", .argv = &.{"codex-acp"} },
    .{ .id = "claude", .name = "Claude Code", .argv = &.{"claude-agent-acp"} },
    .{ .id = "mock", .name = "Local mock", .argv = &.{ "python3", "tools/mock_agent.py" } },
};

pub fn validate(config: Config) !void {
    // A roster with nothing in it is a mistake: there would be nothing to
    // start. How many agents there are is not this module's to bound, the
    // same way the number of shells is not the terminal's - the dock lists
    // every lane it has, and the strip draws the tabs that fit.
    if (config.agents.len == 0) return error.AgentCount;
    for (config.agents, 0..) |agent, index| {
        if (agent.id.len == 0 or agent.id.len > 64 or agent.name.len == 0 or agent.name.len > 64 or agent.argv.len == 0 or agent.argv.len > 64 or agent.argv[0].len == 0) return error.InvalidAgent;
        for (agent.id) |byte| if (byte < 33 or byte > 126) return error.InvalidAgent;
        for (agent.name) |byte| if (byte < 32 or byte > 126) return error.InvalidAgent;
        for (agent.argv) |arg| {
            if (arg.len > 16 * 1024) return error.InvalidAgent;
            for (arg) |byte| if (byte == 0) return error.InvalidAgent;
        }
        if (agent.auth) |auth| {
            if (auth.len == 0 or auth.len > 128) return error.InvalidAgent;
            for (auth) |byte| if (byte < 33 or byte > 126) return error.InvalidAgent;
        }
        if (agent.cwd) |cwd| {
            if (!std.fs.path.isAbsolute(cwd)) return error.AbsoluteCwdRequired;
            for (cwd) |byte| if (byte == 0) return error.InvalidAgent;
        }
        for (config.agents[0..index]) |other| if (std.mem.eql(u8, agent.id, other.id)) return error.DuplicateAgentId;
    }
}

test "first-class presets and unique IDs" {
    try validate(.{});
    try std.testing.expectEqualStrings("acp", builtins[0].argv[1]);
    try std.testing.expectEqualStrings("codex-acp", builtins[1].argv[0]);
    try std.testing.expectEqualStrings("claude-agent-acp", builtins[2].argv[0]);
    try std.testing.expectError(error.DuplicateAgentId, validate(.{ .agents = &.{ builtins[0], builtins[0] } }));
}

test "a roster larger than a strip can show is still a valid roster" {
    // The strip is where the number of tabs comes from, so a dozen lanes is a
    // dock that draws what fits rather than a config that refuses to load.
    // What is still refused is a roster with nothing in it.
    var ids: [12][8]u8 = undefined;
    var roster: [12]Agent = undefined;
    for (&roster, 0..) |*agent, index| {
        const id = std.fmt.bufPrint(&ids[index], "lane-{d}", .{index}) catch unreachable;
        agent.* = .{ .id = id, .name = "Lane", .argv = &.{"lane-acp"} };
    }
    try validate(.{ .agents = &roster });
    try std.testing.expectError(error.AgentCount, validate(.{ .agents = &.{} }));
}
