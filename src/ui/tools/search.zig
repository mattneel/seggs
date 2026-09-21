//! A search-shaped call: what was looked for, where, and what it found.
//!
//! A search and a fetch are this one card: the difference is that a fetch's
//! subject is a URL and it has no match count, which is a config - its own
//! field labels and an empty list where the count would be - rather than a
//! second renderer. A search's count is shown exactly as the record reported
//! it: a count nothing reported is a number this shape will not invent.

const std = @import("std");
const acp = @import("../../acp/tool_call.zig");
const tool_card = @import("../tool_card.zig");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    /// What was looked for.
    query: []const []const u8 = &.{"query"},
    /// Where it looked.
    where: []const []const u8 = &.{"path"},
    /// How many it found.
    count: []const []const u8 = &.{"matches"},
    /// What came back.
    output: []const []const u8 = &.{ "output", "result" },
    /// What the bars are called.
    query_label: []const u8 = "query",
    where_label: []const u8 = "in",
    count_label: []const u8 = "matches",
    output_label: []const u8 = "result",
    /// The verb the lane's line uses: what it is doing.
    doing: []const u8 = "searching",
    /// How much the drawer puts around the card. A search and a fetch are reads
    /// by another name: what they found is worth a line, and the structure
    /// waits for the reader who opens them.
    variant: tool_card.Variant = .plain,
};

pub const finds: Config = .{};
/// A fetch: the same card with a URL for a subject and no match count.
pub const fetches: Config = .{
    .query = &.{"url"},
    .query_label = "url",
    .where = &.{},
    .count = &.{},
    .doing = "fetching",
};

pub fn card(call: acp.ToolCall, status: tool_card.Status, expanded: bool, config: Config, a: Allocator) !tool_card.Card {
    var b = tool_card.Builder.init(a, call, status);
    b.variant = config.variant;
    const query = try b.take(config.query);
    const where = try b.take(config.where);
    const count = try b.take(config.count);
    const output = try b.take(config.output);

    // The query is the pill's own line, so its bar appears only when the
    // subject is something else and the query would otherwise not be shown.
    if (query) |value| {
        if (!std.mem.eql(u8, value, call.subject)) try b.bar(config.query_label, value);
    }
    if (where) |value| try b.bar(config.where_label, value);
    if (count) |value| try b.bar(config.count_label, value);
    if (output) |value| try b.value(config.output_label, "", value);
    // The rest of what the agent said arrives with the reader who opened the
    // call: a preview is what the shape is about, not everything in the record.
    if (expanded) try b.rest();
    return b.finish(call.subject, call.diff);
}

/// What the lane is doing, for the activity line: the verb, and the query.
pub fn summary(call: acp.ToolCall, config: Config) tool_card.Summary {
    return tool_card.summary(config.doing, tool_card.about(call, config.query));
}
