//! The registry: which shape draws which kind, and what the lane says it is
//! doing.
//!
//! A kind is bound to a shape and a config, so adding a tool is a row here
//! rather than a file. The things an agent runs fall into a handful of shapes -
//! a command, a file, a search, a change - and the difference between two tools
//! of one shape is projection, not drawing. A kind no shape knows gets the
//! generic card, because a transcript that cannot draw a call is worse than one
//! that draws it plainly, and because a kind nobody has shaped still has to
//! show everything the agent said.

const std = @import("std");
const acp = @import("../../acp/tool_call.zig");
const diff = @import("../diff.zig");
const tool_card = @import("../tool_card.zig");
const change = @import("change.zig");
const command = @import("command.zig");
const file = @import("file.zig");
const generic = @import("generic.zig");
const search = @import("search.zig");
const Allocator = std.mem.Allocator;

/// The words a tool's own name is built from, and the kind each implies.
///
/// The protocol gives a call one of ten kinds and says they are the display
/// hint, so a kind that is present is never second-guessed. But the ten are
/// coarse: everything a coding agent calls that is not a read, an edit, a
/// delete, a move, a search, an execute, a think, a fetch or a mode switch
/// arrives as `other`, and the programmatic name says which of those it is. A
/// tool named `ast_grep` is a search however it was labelled, and `write_file`
/// is a change.
///
/// A name is split on `_`, `-` and `.` before matching, because a tool called
/// `concat_file` contains `cat` and is not a `cat`; the tokens are what the
/// tool's author chose to name, and matching whole tokens is what keeps a
/// substring from deciding what a card looks like.
const named_kinds = [_]struct { word: []const u8, kind: acp.Kind }{
    .{ .word = "read", .kind = .read },
    .{ .word = "cat", .kind = .read },
    .{ .word = "view", .kind = .read },
    .{ .word = "open", .kind = .read },
    .{ .word = "write", .kind = .edit },
    .{ .word = "edit", .kind = .edit },
    .{ .word = "patch", .kind = .edit },
    .{ .word = "replace", .kind = .edit },
    .{ .word = "create", .kind = .edit },
    .{ .word = "delete", .kind = .delete },
    .{ .word = "remove", .kind = .delete },
    .{ .word = "move", .kind = .move },
    .{ .word = "rename", .kind = .move },
    .{ .word = "grep", .kind = .search },
    .{ .word = "search", .kind = .search },
    .{ .word = "find", .kind = .search },
    .{ .word = "glob", .kind = .search },
    .{ .word = "bash", .kind = .execute },
    .{ .word = "exec", .kind = .execute },
    .{ .word = "run", .kind = .execute },
    .{ .word = "shell", .kind = .execute },
    .{ .word = "command", .kind = .execute },
    .{ .word = "terminal", .kind = .execute },
    .{ .word = "fetch", .kind = .fetch },
    .{ .word = "http", .kind = .fetch },
    .{ .word = "web", .kind = .fetch },
};

/// The kind a tool's name implies, or null when the name says nothing this
/// knows. A name is asked only where the kind did not answer: `named_kinds` is
/// ordered, so the first word that matches decides and the result does not
/// depend on which token happened to come first in the name.
fn kindOfName(name: []const u8) ?acp.Kind {
    if (name.len == 0) return null;
    var tokens = std.mem.tokenizeAny(u8, name, "_-.");
    while (tokens.next()) |token| {
        for (named_kinds) |entry| {
            if (std.ascii.eqlIgnoreCase(token, entry.word)) return entry.kind;
        }
    }
    return null;
}

/// The kind a call is drawn as: what the agent said, or - when it said `other`,
/// where everything unclassified lands - what the tool's own name implies.
///
/// One function rather than two, because the card and the activity line are
/// describing the same call: a chip that draws a search while the line beside it
/// says "running" is two parts of one interface disagreeing about what happened.
fn effectiveKind(call: acp.ToolCall) acp.Kind {
    if (call.kind != .other) return call.kind;
    return kindOfName(call.name) orelse .other;
}

/// The card for this call, in the state the record carries.
///
/// Never fails: an unknown tool gets the generic card, and a call the interface
/// cannot afford to dress gets the pill and the record's own subject, because a
/// transcript that cannot draw a call is worse than one that draws it plainly.
pub fn cardFor(call: acp.ToolCall, expanded: bool, a: Allocator) tool_card.Card {
    return cardIn(call, tool_card.Status.of(call.state, false), expanded, a) catch plain(call);
}

/// The card for this call, in a state the caller has already decided.
///
/// This is how a call the reader cancelled is drawn as cancelled rather than as
/// an error: the fact lives at the lane, which knows a cancel is in flight, and
/// not in the record, which ACP gives four states and no more.
pub fn cardIn(call: acp.ToolCall, status: tool_card.Status, expanded: bool, a: Allocator) !tool_card.Card {
    return switch (effectiveKind(call)) {
        .read => file.card(call, status, expanded, file.reads, a),
        .delete => file.card(call, status, expanded, file.deletes, a),
        .move => file.card(call, status, expanded, file.moves, a),
        .edit => change.card(call, status, expanded, change.edits, a),
        .execute => command.card(call, status, expanded, command.runs, a),
        .search => search.card(call, status, expanded, search.finds, a),
        .fetch => search.card(call, status, expanded, search.fetches, a),
        .think, .switch_mode => generic.card(call, status, a),
        .other => if (file.applies(call))
            file.card(call, status, expanded, file.writes, a)
        else
            generic.card(call, status, a),
    };
}

/// What the lane is doing, for the activity line, without coupling a shape to
/// layout: the verb, and the one value the call is about. A renderer knows what
/// is worth saying about its own kind of call, which is why this asks the shape
/// rather than printing the record's subject.
pub fn summaryFor(call: acp.ToolCall) tool_card.Summary {
    return switch (effectiveKind(call)) {
        .read => file.summary(call, file.reads),
        .delete => file.summary(call, file.deletes),
        .move => file.summary(call, file.moves),
        .edit => change.summary(call, change.edits),
        .execute => command.summary(call, command.runs),
        .search => search.summary(call, search.finds),
        .fetch => search.summary(call, search.fetches),
        .think, .switch_mode => generic.summary(call),
        .other => if (file.applies(call)) file.summary(call, file.writes) else generic.summary(call),
    };
}

/// The card for a call the interface could not afford to dress: the tool's own
/// word, the record's subject, and the colour of its state. This is the fallback
/// `cardFor` promises, and the only card that is built without allocating.
fn plain(call: acp.ToolCall) tool_card.Card {
    return .{
        .status = tool_card.kindWord(call.kind),
        .subject = call.subject,
        .tone = tool_card.Status.of(call.state, false).tone(),
    };
}

const testing = std.testing;

/// A unified diff of the shape our reader writes for an edit's two sides.
const fixture_diff =
    \\--- a/src/ui/tool_call.zig
    \\+++ b/src/ui/tool_call.zig
    \\@@ -1,3 +1,4 @@
    \\- const chip = Chip{};
    \\+ const card = Card{};
    \\ }
    \\
;

/// One call, as the reader would have made it from an agent's update.
fn sampleCall(kind: acp.Kind, subject: []const u8, fields: []const acp.Field, diff_bytes: ?[]const u8) acp.ToolCall {
    return .{
        .id = "call",
        .title = "a call",
        // Most updates never carry the programmatic name - the protocol makes it
        // optional - so the shared fixture leaves it out, and the test that
        // needs one builds its own call.
        .name = &.{},
        .terminal_id = &.{},
        .kind = kind,
        .state = .completed,
        .subject = subject,
        .fields = fields,
        .diff = diff_bytes,
        .at = 0,
    };
}

fn hasSection(card: tool_card.Card, label: []const u8) bool {
    for (card.sections) |section| {
        if (std.mem.eql(u8, section.label, label)) return true;
    }
    return false;
}

/// The labels of a card's sections, in order, joined for the tests that are
/// about which shape drew the card rather than about a particular label. A
/// section with no label is the card's body - the digest a generic card opens
/// with - and is named so here rather than looking like a missing name.
fn sectionLabels(a: Allocator, card: tool_card.Card) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (card.sections, 0..) |section, index| {
        if (index > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, if (section.label.len == 0) "(body)" else section.label);
    }
    return out.toOwnedSlice(a);
}

/// The first row of a section, which is what a one-line payload is.
fn firstValue(card: tool_card.Card, label: []const u8) ?[]const u8 {
    for (card.sections) |section| {
        if (!std.mem.eql(u8, section.label, label)) continue;
        if (section.rows.len == 0 or section.rows[0].len == 0) return "";
        return section.rows[0][0].text;
    }
    return null;
}

/// What a section says it is about - its bar's detail - or null when there is
/// no such section.
fn detailOf(card: tool_card.Card, label: []const u8) ?[]const u8 {
    for (card.sections) |section| {
        if (std.mem.eql(u8, section.label, label)) return section.detail;
    }
    return null;
}

test "every kind draws, and a kind with a shape is not drawn as the generic card" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const file_fields = [_]acp.Field{.{ .label = "path", .value = "src/app.zig" }};
    const run_fields = [_]acp.Field{
        .{ .label = "command", .value = "zig build verify" },
        .{ .label = "exit code", .value = "1" },
        .{ .label = "output", .value = "error: the build failed" },
    };
    const search_fields = [_]acp.Field{
        .{ .label = "query", .value = "cardFor" },
        .{ .label = "path", .value = "src/ui" },
        .{ .label = "matches", .value = "12" },
    };
    const fetch_fields = [_]acp.Field{
        .{ .label = "url", .value = "https://example.test/x" },
        .{ .label = "output", .value = "200 OK" },
    };
    const thought_fields = [_]acp.Field{.{ .label = "thought", .value = "the record is thin" }};
    const mode_fields = [_]acp.Field{.{ .label = "mode", .value = "architect" }};

    // A shape is proved by a section only it draws: each of these is the
    // shape's own name for something, which the generic card - one section per
    // field, labelled as the field is - would not produce.
    const reads = try cardIn(sampleCall(.read, "src/app.zig", &file_fields, null), .done, true, a);
    try testing.expectEqualStrings("file", try sectionLabels(a, reads));
    // The file's name is the bar's detail rather than a row under it: a path is
    // what the section is about, and the section's payload is what came back.
    try testing.expectEqualStrings("src/app.zig", detailOf(reads, "file").?);

    // The subject is the file the edit is in, so the card does not say it
    // twice: the diff's bar is what an open edit adds.
    const edit = try cardIn(sampleCall(.edit, "src/app.zig", &file_fields, fixture_diff), .done, true, a);
    try testing.expectEqualStrings("diff", try sectionLabels(a, edit));
    // The stats on the diff's bar are counted from the diff, so a bar with
    // `+1 -1` in it is the parse having happened.
    try testing.expectEqualStrings("+1 -1", edit.sections[0].detail);
    try testing.expectEqualStrings(fixture_diff, edit.diff.?);

    const deleted = try cardIn(sampleCall(.delete, "src/app.zig", &file_fields, null), .done, true, a);
    try testing.expectEqualStrings("file", try sectionLabels(a, deleted));
    const moved = try cardIn(sampleCall(.move, "src/app.zig", &file_fields, null), .done, true, a);
    try testing.expectEqualStrings("file", try sectionLabels(a, moved));

    const executed = try cardIn(sampleCall(.execute, "zig build verify", &run_fields, null), .failed, true, a);
    try testing.expectEqualStrings("exit code, output", try sectionLabels(a, executed));
    // The exit code is a fact of one value, so it is the bar's detail; what the
    // command printed is a payload, so it is rows.
    try testing.expectEqualStrings("1", detailOf(executed, "exit code").?);
    try testing.expectEqualStrings("error: the build failed", firstValue(executed, "output").?);

    const searched = try cardIn(sampleCall(.search, "cardFor", &search_fields, null), .done, true, a);
    try testing.expectEqualStrings("in, matches", try sectionLabels(a, searched));
    try testing.expectEqualStrings("12", detailOf(searched, "matches").?);

    const fetched = try cardIn(sampleCall(.fetch, "https://example.test/x", &fetch_fields, null), .done, true, a);
    try testing.expectEqualStrings("result", try sectionLabels(a, fetched));
    try testing.expectEqualStrings("200 OK", firstValue(fetched, "result").?);

    // A kind no shape knows is the generic card: a digest of what the call was
    // given, then every field under its own name - nothing renamed and nothing
    // dropped.
    const thought = try cardIn(sampleCall(.think, "the record is thin", &thought_fields, null), .done, true, a);
    try testing.expectEqualStrings("(body), thought", try sectionLabels(a, thought));
    const switched = try cardIn(sampleCall(.switch_mode, "", &mode_fields, null), .done, true, a);
    try testing.expectEqualStrings("(body), mode", try sectionLabels(a, switched));

    // `other` is where an agent's own tool lands: with a path it is a file
    // shape, without one the generic card has to carry it.
    const wrote = try cardIn(sampleCall(.other, "src/ui/tool_call.zig", &file_fields, fixture_diff), .done, true, a);
    try testing.expectEqualStrings("file, diff", try sectionLabels(a, wrote));
    const unknown = try cardIn(sampleCall(.other, "", &mode_fields, null), .done, true, a);
    try testing.expectEqualStrings("(body), mode", try sectionLabels(a, unknown));
}

test "a call the kind could not place is placed by the tool's own name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const search_fields = [_]acp.Field{
        .{ .label = "query", .value = "cardFor" },
        .{ .label = "matches", .value = "12" },
    };
    const vague_fields = [_]acp.Field{.{ .label = "note", .value = "whatever" }};

    // `other` is where every tool the protocol does not classify lands, so for
    // these the name is the only thing that says what the call is: the same
    // fields under the same kind draw as a search or as the generic card
    // depending on nothing but what the tool is called.
    var named = sampleCall(.other, "cardFor", &search_fields, null);
    named.name = "ast_grep";
    var unknown = sampleCall(.other, "", &vague_fields, null);
    unknown.name = "concat_file";

    // `ast_grep` is a search, and the card says so the way a search does - its
    // matches are their own section rather than a field under its own name, as
    // the generic card would have drawn them.
    const searched = try cardIn(named, .done, true, a);
    try testing.expectEqualStrings("matches", try sectionLabels(a, searched));
    try testing.expectEqualStrings("12", detailOf(searched, "matches").?);

    // A name is matched by its tokens and not by its letters: `concat_file`
    // contains `cat` and is not a read, so it stays where the kind left it.
    const vague = try cardIn(unknown, .done, true, a);
    try testing.expectEqualStrings("(body), note", try sectionLabels(a, vague));
}

test "the generic card shows a call with fields and a diff, the way it always has" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fields = [_]acp.Field{
        .{ .label = "mode", .value = "architect" },
        .{ .label = "bytes", .value = "4821" },
    };
    const card = try cardIn(sampleCall(.switch_mode, "a call", &fields, fixture_diff), .done, true, a);

    // The digest first - one dim row of what the call was given, so a reader
    // who never opens it is not looking at a title with nothing behind it -
    // then one labelled section per field, in the record's order, and the diff
    // carried as it arrived.
    try testing.expectEqualStrings("(body), mode, bytes", try sectionLabels(a, card));
    try testing.expectEqualStrings("mode: architect · bytes: 4821", card.sections[0].rows[0][0].text);
    try testing.expectEqual(tool_card.Tone.muted, card.sections[0].rows[0][0].tone);
    try testing.expectEqualStrings("architect", firstValue(card, "mode").?);
    try testing.expectEqualStrings("4821", firstValue(card, "bytes").?);
    try testing.expectEqualStrings(fixture_diff, card.diff.?);
}

test "a call with nothing in it draws its pill and its state, and no digest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const card = cardFor(sampleCall(.other, "", &.{}, null), true, a);
    try testing.expectEqualStrings("tool ✓", card.status);
    try testing.expectEqualStrings("", card.subject);
    try testing.expectEqual(tool_card.Tone.muted, card.tone);
    // A digest of no fields is a stub, and a stub is worse than nothing.
    try testing.expectEqual(@as(usize, 0), card.sections.len);
}

test "the summary says what the lane is doing, and stays sane without a subject" {
    const path = [_]acp.Field{.{ .label = "path", .value = "src/app.zig" }};
    const run = [_]acp.Field{.{ .label = "command", .value = "zig build test" }};

    const reading = summaryFor(sampleCall(.read, "src/app.zig", &path, null));
    try testing.expectEqualStrings("reading", reading.label);
    try testing.expectEqualStrings("src/app.zig", reading.detail);

    // The command comes from the field when the record carries one, which is
    // what makes the lane's line better than the raw subject.
    const running = summaryFor(sampleCall(.execute, "Run zig build test", &run, null));
    try testing.expectEqualStrings("running", running.label);
    try testing.expectEqualStrings("zig build test", running.detail);

    // A call whose subject is empty still has the record's title to say, and a
    // verb to lead with either way.
    const titled = summaryFor(sampleCall(.search, "", &.{}, null));
    try testing.expectEqualStrings("searching", titled.label);
    try testing.expectEqualStrings("a call", titled.detail);

    // A call with nothing at all: no detail to invent, and a verb that still
    // reads as a sentence rather than as a gap.
    var bare = sampleCall(.search, "", &.{}, null);
    bare.title = "";
    const empty = summaryFor(bare);
    try testing.expectEqualStrings("searching", empty.label);
    try testing.expectEqualStrings("", empty.detail);
}

/// The four calls `--exercise-toolcalls` draws: a read that finished, an edit
/// carrying a diff, a command that failed, and a command still running. The
/// census below is the test that the registry does something: a registry that
/// drew everything the same way would pass every other test here.
const fixture = struct {
    const read_fields = [_]acp.Field{.{ .label = "path", .value = "src/app.zig" }};
    const edit_fields = [_]acp.Field{.{ .label = "path", .value = "src/ui/tool_call.zig" }};
    const failed_fields = [_]acp.Field{
        .{ .label = "command", .value = "zig build verify" },
        .{ .label = "exit code", .value = "1" },
        .{ .label = "output", .value = "error: the build failed" },
    };
    const running_fields = [_]acp.Field{.{ .label = "command", .value = "zig build test" }};

    fn calls(diff_bytes: []const u8) [4]acp.ToolCall {
        var out: [4]acp.ToolCall = undefined;
        out[0] = sampleCall(.read, "src/app.zig", &read_fields, null);
        out[1] = sampleCall(.edit, "src/ui/tool_call.zig", &edit_fields, diff_bytes);
        out[2] = sampleCall(.execute, "zig build verify", &failed_fields, null);
        out[2].state = .failed;
        out[3] = sampleCall(.execute, "zig build test", &running_fields, null);
        out[3].state = .in_progress;
        return out;
    }
};

test "the fixture's four calls render differently, which is the point of the registry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const calls = fixture.calls(fixture_diff);

    var labels: [4][]const u8 = undefined;
    for (calls, 0..) |c, index| {
        const status = tool_card.Status.of(c.state, false);
        const card = try cardIn(c, status, false, a);
        labels[index] = try sectionLabels(a, card);
        std.debug.print("calls: {s} {s} · {s} · sections [{s}]\n", .{
            card.status,
            card.subject,
            @tagName(card.variant),
            labels[index],
        });
        // The state is carried by the glyph and the tone, and the tone is what
        // makes a settled call recede: three states, three readings.
        if (index == 0) {
            try testing.expectEqual(tool_card.Tone.muted, card.tone);
            try testing.expectEqual(tool_card.Variant.plain, card.variant);
        }
        if (index == 2) {
            try testing.expectEqual(tool_card.Tone.danger, card.tone);
            // A failure is never quiet, whatever shape drew it.
            try testing.expectEqual(tool_card.Variant.framed, card.variant);
        }
        if (index == 3) {
            try testing.expectEqual(tool_card.Tone.accent, card.tone);
            try testing.expect(card.partial);
        }
    }

    // What a reader sees is not one shape four times: the read names a file and
    // stays a line in the flow, the edit frames itself around a diff and its
    // stats, the failed command names an exit code and its output, and the
    // running one has nothing to name yet.
    try testing.expectEqualStrings("file", labels[0]);
    try testing.expectEqualStrings("diff", labels[1]);
    try testing.expectEqualStrings("exit code, output", labels[2]);
    try testing.expectEqualStrings("", labels[3]);
    try testing.expect(!std.mem.eql(u8, labels[0], labels[1]));
    try testing.expect(!std.mem.eql(u8, labels[1], labels[2]));
}

test "the kinds no shape knows land on the generic card by name, not by accident" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fields = [_]acp.Field{
        .{ .label = "mode", .value = "architect" },
        .{ .label = "detail", .value = "x" },
    };
    // The generic card is the one that shows every field, in the record's
    // order, under the field's own label, after its digest. A kind listed here
    // has no shape of its own yet: shaping one is a row in `cardIn`, and this
    // list is what says which kinds are still standing on the fallback rather
    // than being covered by accident.
    for ([_]acp.Kind{ .think, .switch_mode, .other }) |kind| {
        const card = try cardIn(sampleCall(kind, "a subject", &fields, null), .done, true, a);
        try testing.expectEqualStrings("(body), mode, detail", try sectionLabels(a, card));
    }
}

test "a diff past its budget stops at a line, and its marker costs a row of the budget" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Lines long enough to wrap, so the budget runs out in the middle of the
    // diff rather than at its end.
    const text =
        \\--- a/src/one.zig
        \\+++ b/src/one.zig
        \\@@ -1,2 +1,2 @@
        \\-const one = open("a/very/long/path/that/wraps/somewhere.zig").one;
        \\+const two = open("a/very/long/path/that/wraps/somewhere.zig").two;
        \\ const three = open("a/very/long/path/that/wraps/somewhere.zig").three;
        \\
    ;
    const files = try diff.parse(a, text);
    const plan = try tool_card.planDiff(a, files, text, 40, false);
    // A line is taken whole or left out, so the drawn rows can never run past
    // the budget - and the marker is one of the budget's rows, not one more.
    try testing.expect(plan.rows() <= tool_card.Rows.diff_preview);
    try testing.expect(plan.height() <= tool_card.Rows.diff_preview);
    try testing.expect(plan.withheld > 0);
    // Open, the same diff is worth several times as many rows.
    const open = try tool_card.planDiff(a, files, text, 40, true);
    try testing.expect(open.rows() > plan.rows());

    // One line longer than the whole budget is drawn cut rather than replaced
    // by a marker that shows the reader nothing. At these columns the line
    // wraps to a dozen rows against a budget of eight.
    var wide: [200]u8 = undefined;
    @memset(&wide, 'y');
    const cut = try tool_card.planDiff(a, null, &wide, 20, false);
    try testing.expectEqual(@as(usize, 1), cut.rows());
    try testing.expectEqual(@as(usize, 0), cut.withheld);
}

test "a run that begins after a wrapped piece is no overlap, not an underflow" {
    // A piece covering the first ten bytes of a line, and a run that starts
    // twenty bytes in. This is what a *changed* line produces: the mark is a
    // word near the end, the line breaks across display rows, and the piece
    // being drawn stops before the mark's run begins. Measured the obvious way
    // it is `end - at` with `end < at`, which is an integer underflow and a
    // panic in a debug build.
    const piece = tool_card.Stretch{ .from = 0, .to = 10 };
    try testing.expect(tool_card.overlap(piece, .{ .from = 20, .to = 24 }) == null);
    // A run that begins exactly where the piece ends does not meet it either.
    try testing.expect(tool_card.overlap(piece, .{ .from = 10, .to = 14 }) == null);
    // A run the piece runs into is measured from the run's own start, which is
    // what a caller slices the run's text with.
    const part = tool_card.overlap(piece, .{ .from = 4, .to = 30 }).?;
    try testing.expectEqual(@as(usize, 0), part.from);
    try testing.expectEqual(@as(usize, 6), part.to);
    // A run the piece covers whole.
    const whole = tool_card.overlap(piece, .{ .from = 2, .to = 6 }).?;
    try testing.expectEqual(@as(usize, 0), whole.from);
    try testing.expectEqual(@as(usize, 4), whole.to);
    // And a run that begins before the piece is measured from where the piece
    // starts inside it.
    const tail = tool_card.overlap(.{ .from = 8, .to = 12 }, .{ .from = 4, .to = 20 }).?;
    try testing.expectEqual(@as(usize, 4), tail.from);
    try testing.expectEqual(@as(usize, 8), tail.to);
}

test "a payload past a budget is capped, and the marker names what it left out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A section of one-line rows: the rows a budget counts are the rows the
    // card holds, and the card keeps all of them - a shape drops nothing, and
    // the plan is what decides how many are drawn.
    var payload: [20][]const tool_card.Span = undefined;
    for (&payload, 0..) |*row, index| {
        const line = try std.fmt.allocPrint(a, "line {d}", .{index});
        row.* = try a.dupe(tool_card.Span, &.{.{ .text = line }});
    }
    const section = tool_card.Section{ .label = "output", .rows = &payload };
    const columns: usize = 40;

    // Shut, the payload is a preview: two rows drawn and the marker's own row,
    // which is one of the budget's three rather than one more than it.
    const shut = try tool_card.plan(a, section, columns, false);
    try testing.expectEqual(@as(usize, 2), shut.steps.len);
    try testing.expectEqual(@as(usize, 18), shut.withheld);
    try testing.expectEqual(@as(usize, 2), shut.rows());
    try testing.expectEqual(@as(usize, 3), shut.height());
    // Open, the same payload is worth several times that, which is what makes
    // the key do something rather than redraw the card it just drew.
    const open = try tool_card.plan(a, section, columns, true);
    try testing.expectEqual(@as(usize, 9), open.steps.len);
    try testing.expectEqual(@as(usize, 11), open.withheld);
    try testing.expectEqual(@as(usize, 10), open.height());

    // The marker names how many lines were left out, and which end they went
    // from - and while the reader can still open the call, the key that shows
    // them. An open call has nothing more to give and says nothing about a key.
    const head = try tool_card.moreText(a, shut.withheld, true, .head);
    try testing.expect(std.mem.indexOf(u8, head, "18 more lines") != null);
    try testing.expect(std.mem.indexOf(u8, head, "ctrl+o") != null);
    const tail = try tool_card.moreText(a, shut.withheld, false, .tail);
    try testing.expect(std.mem.indexOf(u8, tail, "18 lines above") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "ctrl+o") == null);

    // A payload whose end is kept shows its end: the last rows, in reading
    // order, with what it left out counted above them.
    const kept = try tool_card.plan(a, .{ .label = "output", .rows = &payload, .edge = .tail }, columns, false);
    try testing.expectEqual(@as(usize, 2), kept.steps.len);
    try testing.expectEqual(@as(usize, 18), kept.steps[0].line);
    try testing.expectEqual(@as(usize, 19), kept.steps[1].line);

    // A payload that fits has nothing to say about lines that are all there.
    const fits = try tool_card.plan(a, .{ .label = "output", .rows = payload[0..2] }, columns, false);
    try testing.expectEqual(@as(usize, 2), fits.steps.len);
    try testing.expectEqual(@as(usize, 0), fits.withheld);
    try testing.expectEqual(@as(usize, 2), fits.height());

    // One row longer than the whole budget is drawn cut, with an ellipsis,
    // rather than replaced by a marker that shows the reader nothing.
    var wide: [200]u8 = undefined;
    @memset(&wide, 'x');
    const single = [_][]const tool_card.Span{&.{.{ .text = &wide }}};
    const cut = try tool_card.plan(a, .{ .label = "output", .rows = &single }, columns, false);
    try testing.expectEqual(@as(usize, 1), cut.steps.len);
    try testing.expect(cut.steps[0].cut);
    try testing.expectEqual(@as(usize, 0), cut.withheld);
    try testing.expectEqual(@as(usize, 1), cut.height());
}
