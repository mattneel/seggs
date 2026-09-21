//! A run of session text, as the interface draws it: the agent's reasoning, the
//! user's own words, and a compaction summary.
//!
//! A run is many chunks and one record, and the record's `at` is where it
//! happened, so a run is drawn where a tool call is drawn: interleaved with the
//! calls and the prose by that offset. Drawing reasoning at the end of a
//! transcript draws the reason after the conclusion.
//!
//! Shut, a run is one line: a mark, a label that says what it is, and how much
//! was said. While the record is still `streaming` the mark is the drawer's
//! spinner - `partial` carries that - so a reader of a long turn can see that
//! the agent is working rather than waiting for a transcript that stopped
//! moving. When the run settles the mark stops and the count is final.
//!
//! Open, a run is its text, and the tone is the correctness property of this
//! module: reasoning is drawn `.muted`, which is dimmer than the prose of the
//! answer. A reader skimming must never mistake what the agent thought for what
//! the agent said. The user's own words are not dimmed - they are not the
//! agent's - and a summary is drawn as the block it is, because it is the record
//! of what the session forgot.
//!
//! Bounded text says so: a run the capture cut carries the count that was
//! dropped on its shut line and a row naming it in its body, because a reader
//! who cannot see the cut reads the end of the text as the end of the thought.
//!
//! One tie has no answer in the records: a call and a run can share an offset,
//! because an update that appends no transcript bytes separates them (thinking,
//! a tool call, more thinking, all at one byte). Neither list carries a
//! cross-kind arrival order, so a merge draws the run first and that choice is
//! arbitrary - it costs two adjacent chips their order and nothing else, which
//! is a better trade than a field every producer would have to maintain in order
//! to decide it.

const std = @import("std");
const acp = @import("../acp/stream.zig");
const session_state = @import("../acp/session_state.zig");
const tool_card = @import("tool_card.zig");
const Allocator = std.mem.Allocator;

/// How a channel is read: the words it is called, the tone its text is drawn
/// in, and whether it is a line in the flow or a block.
///
/// The three channels share the machinery and not the styling. Reasoning is the
/// agent thinking to itself, so it is the dimmest thing in the transcript; the
/// user's words are the one voice that is not the agent's; a summary is the
/// agent's account of what it has forgotten, which is a discontinuity and is
/// framed like one.
pub const Styling = struct {
    /// The label while nothing more is arriving.
    label: []const u8,
    /// The label while the run is still arriving, which is the word a reader
    /// glances at to tell thinking from done.
    arriving: []const u8,
    /// The label when the run failed, and when it was cancelled. A compaction is
    /// the one run with those states, and a compaction that failed must not be
    /// labelled with a word that says it worked.
    failed: []const u8,
    cancelled: []const u8,
    /// The label over the text when the reader opens the run.
    body: []const u8,
    /// The tone the run's own text is drawn in.
    body_tone: tool_card.Tone,
    /// Whether the body is drawn under the pill even with the run shut.
    variant: tool_card.Variant,
    /// Whether the label carries the state's mark. The user's own words are not
    /// work in flight, and a mark on them would read as one.
    marked: bool,
};

/// The styling of a channel.
pub fn styling(channel: acp.Channel) Styling {
    return switch (channel) {
        .thought => .{
            .label = "thought",
            .arriving = "thinking",
            // A thought that stopped is a thought that finished: it has neither
            // of these, and they are spelled as its own label so nothing can
            // read a failure into reasoning.
            .failed = "thought",
            .cancelled = "thought",
            .body = "reasoning",
            // Dimmer than the reply, and no brighter than a quotation: the one
            // property a reader skimming depends on.
            .body_tone = .muted,
            // A line in the flow: shut, the pill is the whole run.
            .variant = .plain,
            .marked = true,
        },
        .user => .{
            .label = "you",
            .arriving = "you",
            .failed = "you",
            .cancelled = "you",
            .body = "said",
            // The user's words are speech rather than reasoning, so they are
            // not dimmed: they are the one voice here that is not the agent's.
            .body_tone = .plain,
            .variant = .plain,
            .marked = false,
        },
        .summary => .{
            .label = "compacted",
            .arriving = "compacting",
            .failed = "compaction failed",
            .cancelled = "compaction cancelled",
            .body = "summary",
            .body_tone = .muted,
            // A discontinuity in the conversation is structure, and structure is
            // framed: a summary the reader scrolls past is a summary that
            // explained nothing.
            .variant = .framed,
            .marked = true,
        },
    };
}

/// The card for one run.
pub fn card(record: acp.Stream, a: Allocator) !tool_card.Card {
    const style = styling(record.channel);
    const state = stateOf(record);
    return .{
        .status = try statusLine(style, state, a),
        .subject = try count(record, a),
        .tone = toneOf(style, state),
        .sections = try body(record, style, a),
        // A run still arriving repaints: the drawer draws a moving glyph for
        // it, which is the pulse.
        .partial = state == .running,
        .variant = switch (state) {
            .failed, .aborted => .framed,
            else => style.variant,
        },
    };
}

/// The card for a compaction: the run that carries its summary, read with the
/// state the agent reported for it.
///
/// This is the one place a run's words come from the session state rather than
/// from the run itself, because a compaction is the only run with a lifecycle:
/// it starts, it succeeds, or it fails, and a reader who is shown a summary with
/// no word about which of those happened cannot tell a fold that worked from one
/// that gave up.
pub fn compactionCard(record: acp.Stream, status: ?session_state.Compaction, a: Allocator) !tool_card.Card {
    const style = styling(.summary);
    const state: tool_card.Status = if (status) |reported| switch (reported.status) {
        .in_progress => .running,
        .completed => .done,
        .failed => .failed,
        .cancelled => .aborted,
        .other => .done,
    } else stateOf(record);
    // A compaction that failed says why where a reader sees it: the reason is
    // the whole of what the reader needs from the row.
    const reason = if (status) |reported| reported.reason else "";
    return .{
        .status = try statusLine(style, state, a),
        .subject = if (reason.len != 0) reason else try count(record, a),
        .tone = switch (state) {
            .running => .accent,
            .done => .muted,
            .aborted => .warning,
            .failed => .danger,
            .pending => .plain,
        },
        .sections = try body(record, style, a),
        .partial = state == .running,
        .variant = .framed,
    };
}

/// The state a run is drawn in, from what the record itself knows: a run that is
/// still arriving is running, and one that stopped is done. A run has no failure
/// of its own - a thought that stops is a thought that finished - which is why a
/// compaction's state comes from the session rather than from the record.
fn stateOf(record: acp.Stream) tool_card.Status {
    return if (record.streaming) .running else .done;
}

/// The word a run is called in a state: what it is while it arrives, what it is
/// when it has settled, and what it is when it went wrong.
fn labelOf(style: Styling, state: tool_card.Status) []const u8 {
    return switch (state) {
        .running => style.arriving,
        .failed => style.failed,
        .aborted => style.cancelled,
        else => style.label,
    };
}

/// The pill: the label - `thinking` while the run is arriving, `thought` when it
/// has settled - and the mark that carries the state without colour.
fn statusLine(style: Styling, state: tool_card.Status, a: Allocator) ![]const u8 {
    const label = labelOf(style, state);
    if (!style.marked) return label;
    return std.fmt.allocPrint(a, "{s} {s}", .{ label, state.symbol() });
}

/// The tones a channel is drawn in, and the one state that overrides them.
fn toneOf(style: Styling, state: tool_card.Status) tool_card.Tone {
    return switch (state) {
        // A run still arriving is the accent, which is the same rule the tool
        // cards use for work in flight.
        .running => .accent,
        // The user's words are not the agent's, and they are not dimmed.
        .done => if (style.body_tone == .plain) .plain else .muted,
        .aborted => .warning,
        .failed => .danger,
        .pending => .plain,
    };
}

/// The one line a shut run shows: how much was said, how much the bound left
/// out, and how many parts carried no words at all.
pub fn count(record: acp.Stream, a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, try size(record.text.len, a));
    // A cut says which way it went: this capture keeps the start of a run and
    // drops the end, so the run continues rather than beginning earlier.
    if (record.truncated) {
        try out.appendSlice(a, " · ");
        try out.appendSlice(a, try size(record.dropped_bytes, a));
        try out.appendSlice(a, " more");
    }
    if (record.other_parts != 0) {
        try out.appendSlice(a, " · ");
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{d} part{s} not text", .{ record.other_parts, if (record.other_parts == 1) "" else "s" }));
    }
    return out.toOwnedSlice(a);
}

/// A byte count with its unit, which is the honest thing to count here: the
/// client sees bytes and nothing else, a token count would need the agent's
/// tokenizer, and the tokens a session does report are the context's rather than
/// one run's. The unit is always printed, so `4.2 kB` can never be read as
/// tokens.
pub fn size(bytes: usize, a: Allocator) ![]const u8 {
    var scratch: [24]u8 = undefined;
    return a.dupe(u8, sizeText(&scratch, bytes));
}

/// The same formatter, written into a buffer the caller owns: the activity line
/// is composed on a frame and must not allocate to say how much has arrived.
/// The answer is a slice of `scratch`, so it lives as long as the buffer does.
pub fn sizeText(scratch: []u8, bytes: usize) []const u8 {
    const written = if (bytes < 1_000)
        std.fmt.bufPrint(scratch, "{d} B", .{bytes})
    else if (bytes < 1_000_000)
        std.fmt.bufPrint(scratch, "{d}.{d} kB", .{ bytes / 1_000, (bytes / 100) % 10 })
    else
        std.fmt.bufPrint(scratch, "{d}.{d} MB", .{ bytes / 1_000_000, (bytes / 100_000) % 10 });
    // A buffer too small for a byte count is a caller's sizing mistake rather
    // than something to panic about: it gets what fits, and 24 bytes fit every
    // count this can produce.
    return written catch scratch[0..0];
}

/// What a lane is doing when it is calling nothing: the newest run that is still
/// arriving, in the words its channel uses - `thinking 54 B`, `compacting 1.2 kB`
/// - written into `buf`, which the caller owns.
///
/// This is the answer to "is it working?" on a lane that has called no tool and
/// has said nothing in prose yet: without it the activity line is blank through
/// the part of a turn where a reader most wants to know, and a blank line is
/// what makes a long turn look stuck. Null when nothing is arriving, which is
/// the honest answer for a lane that has stopped - the caller keeps its own
/// words rather than being told a run is live when none is.
pub fn liveSummary(records: []const acp.Stream, buf: []u8) ?[]const u8 {
    var index = records.len;
    while (index > 0) {
        index -= 1;
        const record = records[index];
        if (!record.streaming) continue;
        const label = styling(record.channel).arriving;
        // Nothing said yet is a label and nothing else: a count of zero bytes
        // beside a run that is about to speak is noise.
        if (record.text.len == 0) return fill(buf, label, label.len);
        var amount: [24]u8 = undefined;
        var line: [96]u8 = undefined;
        const written = std.fmt.bufPrint(&line, "{s} {s}", .{ label, sizeText(&amount, record.text.len) }) catch label;
        return fill(buf, written, written.len);
    }
    return null;
}

/// `text` in `buf`, as much of it as fits. A caller that handed in a one-byte
/// buffer gets one byte rather than a panic, which is the same contract
/// `ui/activity.zig` keeps for the line it is given.
fn fill(buf: []u8, text: []const u8, len: usize) []const u8 {
    const take = @min(buf.len, len);
    @memcpy(buf[0..take], text[0..take]);
    return buf[0..take];
}

/// The run's text, as the rows the reader opens it to see: one row per line,
/// in the tone its channel is read in.
fn body(record: acp.Stream, style: Styling, a: Allocator) ![]const tool_card.Section {
    if (record.text.len == 0 and record.dropped_bytes == 0) return &.{};
    var rows: std.ArrayList([]const tool_card.Span) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, record.text, "\r\n"), '\n');
    while (lines.next()) |line| {
        const spans = try a.alloc(tool_card.Span, 1);
        spans[0] = .{ .text = std.mem.trimEnd(u8, line, "\r"), .tone = style.body_tone };
        try rows.append(a, spans);
    }
    if (record.truncated) try rows.append(a, try cutRow(record, a));
    const sections = try a.alloc(tool_card.Section, 1);
    // A labelled section, so a shut run is one line: the drawer keeps a labelled
    // body for the reader who opens it.
    sections[0] = .{ .label = style.body, .rows = try rows.toOwnedSlice(a), .edge = .head };
    return sections;
}

/// The row that names what the bound left out, at the end of the text where the
/// cut is: the shut line carries the count, and this is where a reader who
/// opened the run finds the hole. It measures bytes and says bytes - the one
/// unit this reader has.
fn cutRow(record: acp.Stream, a: Allocator) ![]const tool_card.Span {
    const spans = try a.alloc(tool_card.Span, 1);
    spans[0] = .{
        .text = try std.fmt.allocPrint(a, "… {s} more was said", .{try size(record.dropped_bytes, a)}),
        .tone = .muted,
    };
    return spans;
}

test "shut, a run is one line: a label, a mark and how much was said" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();

    const streaming: acp.Stream = .{
        .channel = .thought,
        .seq = 1,
        .key = "",
        .text = "the transcript throws thinking away, so I will keep it",
        .at = 40,
        .streaming = true,
        .truncated = false,
        .dropped_bytes = 0,
        .chunks = 12,
        .other_parts = 0,
    };
    const live = try card(streaming, frame);
    // The label says what is happening, and `partial` is what makes the mark
    // move: this is the pulse.
    try std.testing.expectEqualStrings("thinking ●", live.status);
    try std.testing.expect(live.partial);
    try std.testing.expectEqual(tool_card.Tone.accent, live.tone);
    try std.testing.expectEqualStrings("54 B", live.subject);
    // Shut, nothing of the reasoning is on screen: the body is a labelled
    // section, which the drawer keeps for the reader who opens the run.
    try std.testing.expectEqual(tool_card.Variant.plain, live.variant);
    try std.testing.expectEqualStrings("reasoning", live.sections[0].label);
    try std.testing.expectEqual(tool_card.Tone.muted, live.sections[0].rows[0][0].tone);

    // Settled, the pulse stops and the count is what it is.
    var settled = streaming;
    settled.streaming = false;
    const done = try card(settled, frame);
    try std.testing.expectEqualStrings("thought ✓", done.status);
    try std.testing.expect(!done.partial);
    try std.testing.expectEqual(tool_card.Tone.muted, done.tone);
    try std.testing.expectEqualStrings("54 B", done.subject);
}

test "reasoning is dimmer than the answer, and the user's words are not" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();

    const said: acp.Stream = .{
        .channel = .user,
        .seq = 2,
        .key = "",
        .text = "actually, keep the JSON out of it",
        .at = 0,
        .streaming = false,
        .truncated = false,
        .dropped_bytes = 0,
        .chunks = 1,
        .other_parts = 0,
    };
    const user = try card(said, frame);
    // The user's words carry no mark, because they are not work in flight.
    try std.testing.expectEqualStrings("you", user.status);
    try std.testing.expectEqual(tool_card.Tone.plain, user.tone);
    try std.testing.expectEqual(tool_card.Tone.plain, user.sections[0].rows[0][0].tone);
    try std.testing.expectEqualStrings("said", user.sections[0].label);

    const thought = try card(.{ .channel = .thought, .seq = 3, .key = "", .text = "hmm", .at = 0, .streaming = false, .truncated = false, .dropped_bytes = 0, .chunks = 1, .other_parts = 0 }, frame);
    // The one property a reader skimming depends on: reasoning is dimmer than
    // the prose of the answer, and no brighter than a quotation.
    try std.testing.expectEqual(tool_card.Tone.muted, thought.sections[0].rows[0][0].tone);
}

test "a cut run says so on its line and where the hole is" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();

    const cut: acp.Stream = .{
        .channel = .thought,
        .seq = 4,
        .key = "",
        .text = "a thought that ran past what a thought may hold",
        .at = 0,
        .streaming = false,
        .truncated = true,
        .dropped_bytes = 12_400,
        .chunks = 900,
        .other_parts = 2,
    };
    const card_value = try card(cut, frame);
    // The shut line carries the size, what the bound left out and which way it
    // went, and the parts that carried no words at all.
    try std.testing.expectEqualStrings("47 B · 12.4 kB more · 2 parts not text", card_value.subject);
    // Opened, the hole is named where it is, at the end of what was kept.
    const rows = card_value.sections[0].rows;
    try std.testing.expectEqualStrings("… 12.4 kB more was said", rows[rows.len - 1][0].text);
    try std.testing.expectEqual(tool_card.Tone.muted, rows[rows.len - 1][0].tone);
}

test "a compaction is the run with a lifecycle, and it is a block" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();

    const run: acp.Stream = .{
        .channel = .summary,
        .seq = 5,
        .key = "c1",
        .text = "we were overhauling the transcript, so I kept the record and dropped the JSON",
        .at = 120,
        .streaming = true,
        .truncated = false,
        .dropped_bytes = 0,
        .chunks = 6,
        .other_parts = 0,
    };
    const working = try compactionCard(run, .{ .id = "c1", .status = .in_progress, .reason = "" }, frame);
    try std.testing.expectEqualStrings("compacting ●", working.status);
    try std.testing.expect(working.partial);
    // Framed while it happens: a discontinuity the reader scrolls past is one
    // that explained nothing.
    try std.testing.expectEqual(tool_card.Variant.framed, working.variant);
    try std.testing.expectEqualStrings("summary", working.sections[0].label);

    const finished = try compactionCard(run, .{ .id = "c1", .status = .completed, .reason = "" }, frame);
    try std.testing.expectEqualStrings("compacted ✓", finished.status);
    try std.testing.expect(!finished.partial);

    // A failure says why on the line a reader sees, and is framed whatever the
    // channel's own styling says.
    const failed = try compactionCard(run, .{ .id = "c1", .status = .failed, .reason = "the provider refused the summary" }, frame);
    try std.testing.expectEqualStrings("compaction failed ✗", failed.status);
    try std.testing.expectEqualStrings("the provider refused the summary", failed.subject);
    try std.testing.expectEqual(tool_card.Tone.danger, failed.tone);
    try std.testing.expectEqual(tool_card.Variant.framed, failed.variant);

    // With no state reported, the run's own is used rather than a guess.
    const unknown = try compactionCard(run, null, frame);
    try std.testing.expectEqualStrings("compacting ●", unknown.status);
}

test "a lane that is only thinking says so on its own line" {
    const a = std.testing.allocator;
    var line: [96]u8 = undefined;

    // Nothing is arriving: the caller keeps its own words.
    try std.testing.expectEqual(@as(?[]const u8, null), liveSummary(&.{}, &line));

    var settled = [_]acp.Stream{try acp.begin(a, .thought, "", 0, 1)};
    defer acp.deinit(&settled[0], a);
    // `begin` opens a run, so a run that has stopped is one the client has
    // closed: a settled run is not something a lane is doing.
    settled[0].streaming = false;
    settled[0].text = try a.dupe(u8, "a thought that finished");
    try std.testing.expectEqual(@as(?[]const u8, null), liveSummary(&settled, &line));

    // A run still arriving is the lane's work, in its own words and with the one
    // number a reader cannot guess.
    var live = [_]acp.Stream{try acp.begin(a, .thought, "", 0, 2)};
    defer acp.deinit(&live[0], a);
    live[0].text = try a.dupe(u8, "thinking about the widget");
    live[0].streaming = true;
    try std.testing.expectEqualStrings("thinking 25 B", liveSummary(&live, &line).?);

    // A compaction arriving is the lane compacting, which is the same rule for
    // the other channel that has a lifecycle.
    var compacting = [_]acp.Stream{try acp.begin(a, .summary, "c1", 0, 3)};
    defer acp.deinit(&compacting[0], a);
    compacting[0].streaming = true;
    try std.testing.expectEqualStrings("compacting", liveSummary(&compacting, &line).?);

    // The newest arriving run is the one named, and a buffer too small for the
    // line is not a panic.
    var both = [_]acp.Stream{ live[0], compacting[0] };
    try std.testing.expectEqualStrings("compacting", liveSummary(&both, &line).?);
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("comp", liveSummary(&both, &tiny).?);
}

test "a byte count is written the same way with and without an allocator" {
    const a = std.testing.allocator;
    const cases = [_]struct { bytes: usize, text: []const u8 }{
        .{ .bytes = 0, .text = "0 B" },
        .{ .bytes = 999, .text = "999 B" },
        .{ .bytes = 1_000, .text = "1.0 kB" },
        .{ .bytes = 54, .text = "54 B" },
        .{ .bytes = 12_400, .text = "12.4 kB" },
        .{ .bytes = 2_500_000, .text = "2.5 MB" },
    };
    var scratch: [24]u8 = undefined;
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.text, sizeText(&scratch, case.bytes));
        const owned = try size(case.bytes, a);
        defer a.free(owned);
        try std.testing.expectEqualStrings(case.text, owned);
    }
}
