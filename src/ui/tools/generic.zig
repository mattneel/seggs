//! The card a call gets when no shape knows it: the labelled fields and the
//! diff the transcript has always drawn.
//!
//! This is the fallback, and it is deliberately complete rather than clever. A
//! kind nobody has a shape for still shows every field the record carries and
//! its diff, which is what makes adding a shape an improvement rather than a
//! repair - and what makes the generic card the reference for "nothing is
//! dropped". Nothing here reads the expansion state: every field it has is
//! worth showing, and the drawer's budget decides how much of each is a
//! preview.

const std = @import("std");
const acp = @import("../../acp/tool_call.zig");
const tool_card = @import("../tool_card.zig");
const Allocator = std.mem.Allocator;

pub fn card(call: acp.ToolCall, status: tool_card.Status, a: Allocator) !tool_card.Card {
    var b = tool_card.Builder.init(a, call, status);
    // A call nobody has shaped is quiet: a thought, a mode switch, or a tool
    // this interface has not met are lines in the flow, and their structure is
    // for the reader who opens them. A failure is framed whatever shape drew
    // it, which `finish` is what decides.
    b.variant = .plain;
    // A call nobody has shaped is read for what it was given, so a reader who
    // never opens it is not looking at a title with nothing behind it. The
    // digest is one row whatever the number of fields - three fields cannot
    // grow the shut card, and thirty cannot either - and the drawer's budget
    // is what bounds it on screen.
    if (try digest(a, call)) |line| try b.digest(line);
    for (call.fields) |field| try b.field(field);
    return b.finish(call.subject, call.diff);
}

/// The arguments of a call as the one dim row a shut card shows: `label: value`
/// for each field the record carries, joined. Nothing at all when there is
/// nothing to say, because a digest of nothing is a stub.
fn digest(a: Allocator, call: acp.ToolCall) !?[]u8 {
    if (call.fields.len == 0) return null;
    var line: std.ArrayList(u8) = .empty;
    for (call.fields, 0..) |field, index| {
        if (index > 0) try line.appendSlice(a, " · ");
        try line.appendSlice(a, field.label);
        try line.appendSlice(a, ": ");
        try line.appendSlice(a, field.value);
    }
    const owned = try line.toOwnedSlice(a);
    return owned;
}

/// What the lane is doing, for the activity line. A call no shape knows is
/// still a call: the kind names the verb where it has one, and the detail is
/// whatever the record is about.
pub fn summary(call: acp.ToolCall) tool_card.Summary {
    const label = switch (call.kind) {
        .think => "thinking",
        .switch_mode => "switching",
        .delete => "deleting",
        .move => "moving",
        else => "using",
    };
    return tool_card.summary(label, tool_card.about(call, &.{ "thought", "path", "mode", "command", "query", "url" }));
}
