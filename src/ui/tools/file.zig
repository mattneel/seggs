//! A file-shaped call: one path, and what the tool did with it.
//!
//! A file that was read, deleted, or moved is one card with different verbs,
//! and a file-writing tool that lands in `other` is the same card again. So the
//! shape is the builder and the tool is the config it binds: what differs
//! between them is projection - which fields name the file, what the result is
//! called - and projection is config rather than drawing.
//!
//! Nothing here invents a fact the record does not carry. A read with no line
//! in it shows no line; a value the reader would have to guess at is a value
//! this shape leaves out.

const std = @import("std");
const acp = @import("../../acp/tool_call.zig");
const tool_card = @import("../tool_card.zig");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    /// The fields that name the file, most specific first.
    path: []const []const u8 = &.{"path"},
    /// Where in it: a location's line, or what a reading was paged with.
    line: []const []const u8 = &.{"line"},
    offset: []const []const u8 = &.{"offset"},
    limit: []const []const u8 = &.{"limit"},
    /// What came back.
    result: []const []const u8 = &.{ "output", "result" },
    /// What the bars are called.
    file_label: []const u8 = "file",
    line_label: []const u8 = "line",
    result_label: []const u8 = "result",
    /// The bar a carried diff gets, when the tool writes as well as names a
    /// file. Empty for a shape that never carries one.
    diff_label: []const u8 = "",
    /// The verb the lane's line uses: what it is doing to the file.
    doing: []const u8 = "reading",
    /// How much the drawer puts around the card. A read is a line in the flow -
    /// three reads in a row are three lines, not three boxes - while a delete,
    /// a move, and a write changed something and own a gutter.
    variant: tool_card.Variant = .framed,
};

pub const reads: Config = .{ .variant = .plain };
pub const deletes: Config = .{ .doing = "deleting" };
pub const moves: Config = .{ .doing = "moving" };
/// A file-writing tool: an `other` call that names a path, and carries the diff
/// of what it wrote.
pub const writes: Config = .{ .doing = "writing", .diff_label = "diff" };

/// Whether a call is this shape. `other` is where an agent's own file tool
/// lands, and a path is what makes it file-shaped rather than nobody's.
pub fn applies(call: acp.ToolCall) bool {
    const path = tool_card.fieldValue(call, &.{"path"}) orelse return false;
    return path.len != 0;
}

pub fn card(call: acp.ToolCall, status: tool_card.Status, expanded: bool, config: Config, a: Allocator) !tool_card.Card {
    var b = tool_card.Builder.init(a, call, status);
    b.variant = config.variant;
    const path = try b.take(config.path);
    const line = try b.take(config.line);
    const offset = try b.take(config.offset);
    const limit = try b.take(config.limit);
    const result = try b.take(config.result);

    // The file is what this shape is about, so it gets a bar even when the pill
    // already names it: the pill elides, and a reader who opened the call came
    // for the path in full.
    if (path) |value| try b.bar(config.file_label, value);
    if (line) |value| try b.bar(config.line_label, value);
    // A reading that was paged says so under the names the record used: turning
    // `offset` and `limit` into a range would be this shape reading a meaning
    // into two fields that never said they were a range.
    if (offset) |value| try b.bar("offset", value);
    if (limit) |value| try b.bar("limit", value);
    if (config.diff_label.len != 0) try tool_card.diffBar(&b, call, config.diff_label);
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
