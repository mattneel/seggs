const std = @import("std");

pub const Agent = struct {
    id: []const u8,
    name: []const u8,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
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
    if (config.agents.len == 0 or config.agents.len > 8) return error.AgentCount;
    for (config.agents, 0..) |agent, index| {
        if (agent.id.len == 0 or agent.id.len > 64 or agent.name.len == 0 or agent.name.len > 64 or agent.argv.len == 0 or agent.argv.len > 64 or agent.argv[0].len == 0) return error.InvalidAgent;
        for (agent.id) |byte| if (byte < 33 or byte > 126) return error.InvalidAgent;
        for (agent.name) |byte| if (byte < 32 or byte > 126) return error.InvalidAgent;
        for (agent.argv) |arg| {
            if (arg.len > 16 * 1024) return error.InvalidAgent;
            for (arg) |byte| if (byte == 0) return error.InvalidAgent;
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
