//! A plan, as the interface draws it: a checklist a reader watches move.
//!
//! A plan is not history. An agent sends one and then replaces it as it works,
//! so the twelfth update is the current intent and not a twelfth plan, and this
//! draws *one record*: the caller keeps one card per plan, reads it again on
//! every frame, and a plan that was taken away is drawn by nothing. The
//! alternative - a card appended to the transcript for every update - is how a
//! reader ends up scrolling past eleven stale plans to find the twelfth.
//!
//! The card says where the plan stands without relying on colour: the status
//! line carries a mark, every task carries its own, and the task being worked
//! on is the one drawn at full brightness. Priority shows only when it is not
//! medium, because a word on every row is a word nobody reads.
//!
//! Nothing here draws and nothing here reads a frame: a `Card` comes out, and
//! `ui/tool_call.zig` is what puts one on screen.

const std = @import("std");
const acp = @import("../acp/plan.zig");
const tool_card = @import("tool_card.zig");
const Allocator = std.mem.Allocator;

/// The card for one plan, in the state its tasks are in. A plan of markdown or
/// of a file has no task list, so it carries no mark: nothing here claims to
/// know the progress of a plan it cannot count.
pub fn card(record: acp.Plan, a: Allocator) !tool_card.Card {
    return .{
        .status = try statusLine(record, a),
        .subject = try subject(record, a),
        .tone = toneOf(record),
        .sections = try sections(record, a),
        // A plan is a block rather than a line: it is the one thing in a
        // transcript a reader looks at to know what is coming.
        .variant = .framed,
    };
}

/// Where the plan stands, or null when it cannot be counted.
fn stateOf(record: acp.Plan) ?tool_card.Status {
    const entries = switch (record.body) {
        .entries => |list| list,
        else => return null,
    };
    if (entries.len == 0) return null;
    var running = false;
    var waiting = false;
    var done: usize = 0;
    for (entries) |entry| switch (entry.status) {
        .in_progress => running = true,
        .completed => done += 1,
        else => waiting = true,
    };
    if (running) return .running;
    if (waiting) return .pending;
    if (done == entries.len) return .done;
    return null;
}

/// The pill: `plan`, and the mark that carries its state without colour.
fn statusLine(record: acp.Plan, a: Allocator) ![]const u8 {
    const state = stateOf(record) orelse return "plan";
    return std.fmt.allocPrint(a, "plan {s}", .{state.symbol()});
}

/// The line a reader scans with the card shut: how much of the plan is done,
/// and what is running - the two numbers that say whether the agent is ahead of
/// what the reader expected. A plan with no tasks has nothing to count.
fn subject(record: acp.Plan, a: Allocator) ![]const u8 {
    switch (record.body) {
        .entries => |entries| {
            if (entries.len == 0) return "";
            var done: usize = 0;
            var running: usize = 0;
            for (entries) |entry| switch (entry.status) {
                .completed => done += 1,
                .in_progress => running += 1,
                else => {},
            };
            if (running == 0) return std.fmt.allocPrint(a, "{d}/{d} done", .{ done, entries.len });
            return std.fmt.allocPrint(a, "{d}/{d} done · {d} running", .{ done, entries.len, running });
        },
        // A plan written as prose is named by its own first line, which is what
        // the agent wrote it to say.
        .markdown => |text| return firstLine(text),
        // A plan the agent kept in a file is named by the file: it is where the
        // reader goes to read the rest.
        .file => |uri| return uri,
    }
}

fn firstLine(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) return trimmed;
    }
    return "";
}

/// Work that is moving is the accent, work that has finished recedes, and a
/// plan that has not started is not shouting about anything.
fn toneOf(record: acp.Plan) tool_card.Tone {
    return switch (stateOf(record) orelse return .plain) {
        .running => .accent,
        .done => .muted,
        else => .plain,
    };
}

fn sections(record: acp.Plan, a: Allocator) ![]const tool_card.Section {
    const rows: []const []const tool_card.Span = switch (record.body) {
        .entries => |entries| try entryRows(entries, a),
        .markdown => |text| try textRows(text, a),
        .file => &.{},
    };
    if (rows.len == 0) return &.{};
    const out = try a.alloc(tool_card.Section, 1);
    // The body, not a labelled section: the checklist *is* the plan, and the
    // drawer shows a body's first rows even with the card shut, which is what
    // makes a plan readable at a glance.
    out[0] = .{ .rows = rows };
    return out;
}

/// One row per task: its mark, its words, and its priority when the priority is
/// worth the width. The task being worked on is drawn at full brightness and
/// the rest recede, which is the reader's answer to "where is it now".
fn entryRows(entries: []const acp.Entry, a: Allocator) ![]const []const tool_card.Span {
    const rows = try a.alloc([]const tool_card.Span, entries.len);
    for (entries, 0..) |entry, index| {
        const mark = switch (entry.status) {
            .completed => tool_card.Status.done.symbol(),
            .in_progress => tool_card.Status.running.symbol(),
            .pending => tool_card.Status.pending.symbol(),
            // A status this reader does not know has no mark to claim, and the
            // point is not to invent one.
            .other => "·",
        };
        const mark_tone: tool_card.Tone = switch (entry.status) {
            .in_progress => .accent,
            else => .muted,
        };
        const words_tone: tool_card.Tone = switch (entry.status) {
            .completed, .other => .muted,
            .pending, .in_progress => .plain,
        };
        var spans: std.ArrayList(tool_card.Span) = .empty;
        try spans.append(a, .{ .text = mark, .tone = mark_tone });
        try spans.append(a, .{ .text = " " });
        try spans.append(a, .{ .text = entry.content, .tone = words_tone });
        // Medium is the priority a task has when nobody said otherwise, so
        // showing it would put a word on every row to say nothing.
        switch (entry.priority) {
            .high => try spans.append(a, .{ .text = " · high", .tone = .warning }),
            .low => try spans.append(a, .{ .text = " · low", .tone = .muted }),
            .medium, .other => {},
        }
        rows[index] = try spans.toOwnedSlice(a);
    }
    return rows;
}

/// A markdown plan's lines, one row each, so the drawer's budget counts the
/// lines a reader would count.
fn textRows(text: []const u8, a: Allocator) ![]const []const tool_card.Span {
    var rows: std.ArrayList([]const tool_card.Span) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\r\n"), '\n');
    while (lines.next()) |line| {
        const spans = try a.alloc(tool_card.Span, 1);
        spans[0] = .{ .text = std.mem.trimEnd(u8, line, "\r") };
        try rows.append(a, spans);
    }
    return rows.toOwnedSlice(a);
}

test "a plan is a checklist, and the task being worked on stands out" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const entries = [_]acp.Entry{
        .{ .content = "read the client", .priority = .high, .status = .completed },
        .{ .content = "capture the thoughts", .priority = .medium, .status = .in_progress },
        .{ .content = "draw them", .priority = .low, .status = .pending },
    };
    const card_value = try card(.{ .id = "", .body = .{ .entries = &entries } }, arena.allocator());

    // The state is in the status line and in the tone, so a reader without
    // colour still sees a plan that is running.
    try std.testing.expectEqualStrings("plan ●", card_value.status);
    try std.testing.expectEqual(tool_card.Tone.accent, card_value.tone);
    try std.testing.expectEqualStrings("1/3 done · 1 running", card_value.subject);
    try std.testing.expectEqual(tool_card.Variant.framed, card_value.variant);

    const rows = card_value.sections[0].rows;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    // A finished task's words recede and an unfinished one's do not: the row a
    // reader is looking for is the one at full brightness.
    try std.testing.expectEqualStrings("✓", rows[0][0].text);
    try std.testing.expectEqual(tool_card.Tone.muted, rows[0][2].tone);
    try std.testing.expectEqualStrings("●", rows[1][0].text);
    try std.testing.expectEqual(tool_card.Tone.accent, rows[1][0].tone);
    try std.testing.expectEqual(tool_card.Tone.plain, rows[1][2].tone);
    try std.testing.expectEqualStrings("○", rows[2][0].text);

    // Priority is shown when it is not medium, which is the one that says
    // nothing.
    try std.testing.expectEqualStrings(" · high", rows[0][rows[0].len - 1].text);
    try std.testing.expectEqual(tool_card.Tone.warning, rows[0][rows[0].len - 1].tone);
    try std.testing.expectEqualStrings(" · low", rows[2][rows[2].len - 1].text);
    try std.testing.expectEqualStrings("capture the thoughts", rows[1][2].text);
    try std.testing.expectEqual(@as(usize, 3), rows[1].len);
}

test "a plan that cannot be counted is drawn without a mark" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Markdown and a file are plans too, and neither one has tasks to count.
    const markdown = try card(.{ .id = "p1", .body = .{ .markdown = "\n1. look at it\n2. fix it\n" } }, arena.allocator());
    try std.testing.expectEqualStrings("plan", markdown.status);
    try std.testing.expectEqualStrings("1. look at it", markdown.subject);
    try std.testing.expectEqual(tool_card.Tone.plain, markdown.tone);

    const file = try card(.{ .id = "p2", .body = .{ .file = "file:///tmp/plan.md" } }, arena.allocator());
    try std.testing.expectEqualStrings("plan", file.status);
    try std.testing.expectEqualStrings("file:///tmp/plan.md", file.subject);
    try std.testing.expectEqual(@as(usize, 0), file.sections.len);

    // A plan whose tasks have all finished says so, and stops competing for the
    // reader's eye.
    const done = [_]acp.Entry{.{ .content = "everything", .priority = .high, .status = .completed }};
    const finished = try card(.{ .id = "p3", .body = .{ .entries = &done } }, arena.allocator());
    try std.testing.expectEqualStrings("plan ✓", finished.status);
    try std.testing.expectEqualStrings("1/1 done", finished.subject);
    try std.testing.expectEqual(tool_card.Tone.muted, finished.tone);

    // A plan with no tasks at all has nothing to count and nothing to draw.
    const empty = try card(.{ .id = "p4", .body = .{ .entries = &.{} } }, arena.allocator());
    try std.testing.expectEqualStrings("plan", empty.status);
    try std.testing.expectEqualStrings("", empty.subject);
    try std.testing.expectEqual(@as(usize, 0), empty.sections.len);
}
