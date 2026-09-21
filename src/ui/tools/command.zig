//! A command-shaped call: a line that ran, where it ran, and what it answered.
//!
//! Every tool that runs something is this card - the shell, a build, a test
//! runner, an agent's own `bash` - and the difference between two of them is
//! which fields hold the command and what the result is called. That is config,
//! so it is bound here rather than written again.
//!
//! A command's card is also where the honesty matters most: an exit code is
//! shown when the call reported one and never when it did not, because a card
//! claiming `exit 0` for a command that is still running is worse than a card
//! saying nothing.

const std = @import("std");
const acp = @import("../../acp/tool_call.zig");
const tool_card = @import("../tool_card.zig");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    /// The fields that hold the command, most specific first.
    command: []const []const u8 = &.{"command"},
    /// Where it ran.
    directory: []const []const u8 = &.{"directory"},
    /// What it exited with. Absent until the command has finished.
    exit: []const []const u8 = &.{"exit code"},
    /// What it printed.
    output: []const []const u8 = &.{ "output", "result" },
    /// What the bars are called.
    command_label: []const u8 = "command",
    directory_label: []const u8 = "directory",
    exit_label: []const u8 = "exit code",
    output_label: []const u8 = "output",
    /// The bar a carried diff gets. Empty for a tool that never produces one.
    diff_label: []const u8 = "",
    /// The verb the lane's line uses: what it is doing.
    doing: []const u8 = "running",
};

pub const runs: Config = .{};
// A command is framed: it ran something, and what it printed is the reason the
// reader is here. The shape's cards are `.framed` by the builder's own default.

pub fn card(call: acp.ToolCall, status: tool_card.Status, expanded: bool, config: Config, a: Allocator) !tool_card.Card {
    var b = tool_card.Builder.init(a, call, status);
    const command = try b.take(config.command);
    const directory = try b.take(config.directory);
    const code = try b.take(config.exit);
    const output = try b.take(config.output);

    // The command is the pill's own line, so the bar is drawn only when the
    // record's subject is something else - the tool's title, in practice - and
    // the command is then worth stating in full.
    if (command) |value| {
        if (!std.mem.eql(u8, value, call.subject)) try b.bar(config.command_label, value);
    }
    if (directory) |value| try b.bar(config.directory_label, value);
    if (code) |value| try b.bar(config.exit_label, value);
    if (config.diff_label.len != 0) try tool_card.diffBar(&b, call, config.diff_label);
    // A command's output is kept from its end: the line that says why it failed
    // is the last one, which a preview of the first lines would never show.
    if (output) |value| try b.output(config.output_label, "", value);
    // The rest of what the agent said arrives with the reader who opened the
    // call: a preview is what the shape is about, not everything in the record.
    if (expanded) try b.rest();
    return b.finish(call.subject, call.diff);
}

/// What the lane is doing, for the activity line: the verb, and the command.
pub fn summary(call: acp.ToolCall, config: Config) tool_card.Summary {
    return tool_card.summary(config.doing, tool_card.about(call, config.command));
}
