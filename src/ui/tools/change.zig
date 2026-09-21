//! A change-shaped call: a file that is now different, and the difference.
//!
//! An edit is the card the diff is the point of, so the diff's section bar
//! carries what a reader scans for before they read a line of it - `+N -M`,
//! counted from the diff itself - and the diff is drawn under it through
//! `ui/diff.zig`, the same path a fenced diff in the prose takes.
//!
//! The file the change is in is the pill's own line, so it gets no second bar
//! unless the record's subject is something else. Nothing is claimed that the
//! record did not report: an edit with no stats is an edit with no bar detail.

const std = @import("std");
const acp = @import("../../acp/tool_call.zig");
const tool_card = @import("../tool_card.zig");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    /// The fields that name the file.
    path: []const []const u8 = &.{"path"},
    /// Where in it.
    line: []const []const u8 = &.{"line"},
    /// What came back.
    result: []const []const u8 = &.{ "output", "result", "error" },
    /// What the bars are called.
    file_label: []const u8 = "file",
    line_label: []const u8 = "line",
    result_label: []const u8 = "result",
    diff_label: []const u8 = "diff",
    /// The verb the lane's line uses: what it is doing to the file.
    doing: []const u8 = "editing",
};

pub const edits: Config = .{};
// A change is the card the gutter is for: it framed itself by changing a file,
// so the shape keeps the builder's own `.framed` default.

pub fn card(call: acp.ToolCall, status: tool_card.Status, expanded: bool, config: Config, a: Allocator) !tool_card.Card {
    var b = tool_card.Builder.init(a, call, status);
    const path = try b.take(config.path);
    const line = try b.take(config.line);
    const result = try b.take(config.result);

    // The diff first: it is what the reader opened the call for, and its bar
    // carries the stats.
    if (config.diff_label.len != 0) try tool_card.diffBar(&b, call, config.diff_label);
    if (line) |value| try b.bar(config.line_label, value);
    if (path) |value| {
        if (!std.mem.eql(u8, value, call.subject)) try b.bar(config.file_label, value);
    }
    if (result) |value| try b.value(config.result_label, "", value);
    // The rest of what the agent said arrives with the reader who opened the
    // call: a preview is what the shape is about, not everything in the record.
    if (expanded) try b.rest();
    return b.finish(call.subject, call.diff);
}

/// What the lane is doing, for the activity line: the verb, and the file.
pub fn summary(call: acp.ToolCall, config: Config) tool_card.Summary {
    return tool_card.summary(config.doing, tool_card.about(call, config.path));
}
