//! Usage and cost, as the interface draws them: the numbers a reader checks to
//! know how much room is left.
//!
//! Two placements are worth having, and this module is the shape of both rather
//! than a decision about which:
//!
//!   - `turnCard` is a row drawn where a turn ended. It is what makes cost
//!     legible: a reader who wants to know what a turn cost sees it beside that
//!     turn. The price is that a long session accumulates them, so a caller
//!     draws them for the turns it still has rather than keeping a second
//!     history beside the transcript.
//!   - `gaugeCard` is one standing line beside the transcript, always the
//!     latest count and never a history. It answers "how full is the context
//!     now" and nothing else: a gauge that showed a past turn would be lying
//!     about being current.
//!
//! The reference does both - a per-turn metric row and a standing one - and that
//! is the recommendation: the gauge for the state now, the turn row for what the
//! turn just cost.
//!
//! What is *absent* and what is *zero* are different states and are drawn
//! differently: a session that has not reported a cost omits the cell, and one
//! that reports a cost of zero shows it, because "we know it is zero" is
//! information a reader must be able to tell from "we do not know". A context of
//! zero tokens at the start of a session is a real count and is drawn too.
//!
//! When the cells do not fit the width the row **drops whole ones from the end**
//! and never truncates a number, because a cut number reads as a different
//! number. Which end that is is a decision about what a reader can reconstruct:
//! the cells are ordered counts, cost, share, gauge, so the bar goes first, the
//! share next, and the cost outlives both.
//!
//! That order is the opposite of the obvious one, and it is deliberate. A bar is
//! a picture of a number already printed beside it, and a share is arithmetic on
//! that number, so both say what the row goes on to say. The cost says something
//! nothing else in the row says, and at a dock's width it is the difference
//! between a reader knowing what a long turn cost and never seeing it at all:
//! `42k/200k · $1.25` fits where `##--- · 42k/200k · 21% · …` does not.

const std = @import("std");
const session_state = @import("../acp/session_state.zig");
const tool_card = @import("tool_card.zig");
const wrap = @import("wrap.zig");
const Allocator = std.mem.Allocator;

/// One cell of a metric row.
///
/// `value` is null when the session never reported the metric, which omits the
/// cell entirely; an empty or zero value is one the session did report, and is
/// drawn as it says. `leading` is glued to the value when a cell has a prefix of
/// its own.
pub const Metric = struct {
    leading: []const u8 = "",
    value: ?[]const u8 = null,
};

/// The most of the width a gauge takes: a bar that fills the row is a bar, and
/// the numbers beside it are what a reader can act on.
pub const max_gauge_cells: usize = 24;

/// The least of it that still reads as a gauge rather than as a speck.
pub const min_gauge_cells: usize = 4;

/// What separates two cells, and therefore what a drop gives back.
const separator = " · ";

/// The row for a turn that has ended: how full the context is and what the
/// session has cost so far.
pub fn turnCard(counts: session_state.Usage, columns: usize, a: Allocator) !tool_card.Card {
    return .{
        .status = "usage",
        .subject = try join(try row(try metrics(counts, columns, a), columns, a), a),
        .tone = toneOf(counts),
        // A row, not a block: it is one line of numbers in the flow, and the
        // drawer's chip is exactly that.
        .variant = .plain,
    };
}

/// The standing line for beside the transcript: the same cells as a turn row,
/// fitted to the width it is given, so what it says at a dock's width is the
/// count and the cost rather than a bar and a percentage. The two placements
/// differ in where they are and what they are labelled - what the turn cost,
/// what the context holds now - not in what they are willing to lose.
pub fn gaugeCard(counts: session_state.Usage, columns: usize, a: Allocator) !tool_card.Card {
    return .{
        .status = "context",
        .subject = try join(try row(try metrics(counts, columns, a), columns, a), a),
        .tone = toneOf(counts),
        .variant = .plain,
    };
}

/// The cells of a row, in the order they are drawn - and so in reverse order of
/// how easily they are dropped, because `row` gives up its end. Counts first
/// (nothing reconstructs them), the cost next (nothing else says it), then the
/// share (arithmetic on the counts), then the gauge (a picture of them).
pub fn metrics(counts: session_state.Usage, columns: usize, a: Allocator) ![]const Metric {
    const cells = try a.alloc(Metric, 4);
    // A window of no tokens is not a window: `1000/0` would read as a session
    // that filled a window of nothing, where the honest answer is the count the
    // session did report and no share of a window it did not.
    cells[0] = .{ .value = if (counts.size == 0)
        try tokens(counts.used, a)
    else
        try std.fmt.allocPrint(a, "{s}/{s}", .{ try tokens(counts.used, a), try tokens(counts.size, a) }) };
    cells[1] = .{ .value = if (counts.cost) |cost| try money(cost, a) else null };
    cells[2] = .{ .value = try share(counts, a) };
    cells[3] = .{ .value = try gauge(counts, columns, a) };
    return cells;
}

/// The share of the window the context is taking, or nothing when there is no
/// window to take a share of: a percentage nobody reported would be a guess
/// about the number a reader is watching.
fn share(counts: session_state.Usage, a: Allocator) !?[]const u8 {
    if (counts.size == 0) return null;
    const text: []const u8 = try std.fmt.allocPrint(a, "{d}%", .{counts.used * 100 / counts.size});
    return text;
}

/// Join the cells that fit the width, dropping whole ones from the end rather
/// than cutting one. The first cell stays whatever happens - a row with nothing
/// in it says less than a row the drawer has to elide.
pub fn row(cells: []const Metric, columns: usize, a: Allocator) ![]const tool_card.Span {
    var spans: std.ArrayList(tool_card.Span) = .empty;
    for (cells) |cell| {
        const value = cell.value orelse continue;
        if (value.len == 0) continue;
        const text = try std.fmt.allocPrint(a, "{s}{s}", .{ cell.leading, value });
        if (spans.items.len != 0 and !fits(try candidate(spans.items, text, a), columns)) break;
        try spans.append(a, .{ .text = text });
    }
    return spans.toOwnedSlice(a);
}

/// The gauge: filled cells, then empty ones, in ASCII - a bar drawn from a glyph
/// the atlas may not carry is a bar that may draw nothing at all. A session with
/// no window to be a share of draws no gauge rather than a full one.
fn gauge(counts: session_state.Usage, columns: usize, a: Allocator) !?[]const u8 {
    if (counts.size == 0) return null;
    const width = gaugeCells(columns);
    if (width < min_gauge_cells) return null;
    const filled = @min(width, (counts.used * width) / counts.size);
    const cells = try a.alloc(u8, width);
    @memset(cells[0..filled], '#');
    @memset(cells[filled..], '-');
    return cells;
}

/// How wide a gauge may be in a row this wide: a third of it, never more than a
/// reader counts at a glance.
pub fn gaugeCells(columns: usize) usize {
    return std.math.clamp(columns / 3, 0, max_gauge_cells);
}

/// A full context is the one state of a usage row worth a colour of its own: it
/// is a turn away from being compacted, which is a thing a reader plans around.
fn toneOf(counts: session_state.Usage) tool_card.Tone {
    return if (counts.size != 0 and counts.used >= counts.size) .warning else .muted;
}

/// Whether `bytes` fits in `columns`: counted with the rule the drawer wraps
/// with, so what fits here is what the drawer draws on one line.
fn fits(bytes: []const u8, columns: usize) bool {
    return columns != 0 and wrap.rowCount(bytes, columns) <= 1;
}

/// The row so far with one more cell appended, which is what the fit test asks
/// about.
fn candidate(spans: []const tool_card.Span, extra: []const u8, a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (spans) |span| {
        try out.appendSlice(a, span.text);
        try out.appendSlice(a, separator);
    }
    try out.appendSlice(a, extra);
    return out.toOwnedSlice(a);
}

/// A row of spans as one line, which is what a card's subject is.
pub fn join(spans: []const tool_card.Span, a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (spans, 0..) |span, index| {
        if (index > 0) try out.appendSlice(a, separator);
        try out.appendSlice(a, span.text);
    }
    return out.toOwnedSlice(a);
}

/// A token count as a reader reads one: the number while it is small, then
/// thousands, then millions. The unit is the whole story - `42k` is forty-two
/// thousand tokens and nothing else - so a reader cannot take it for a byte
/// count.
pub fn tokens(count: u64, a: Allocator) ![]const u8 {
    if (count < 10_000) return std.fmt.allocPrint(a, "{d}", .{count});
    if (count < 1_000_000) return std.fmt.allocPrint(a, "{d}k", .{count / 1_000});
    return std.fmt.allocPrint(a, "{d}.{d}M", .{ count / 1_000_000, (count / 100_000) % 10 });
}

/// What a session has cost, in a currency it named.
///
/// A cost the session reported is always drawn, a zero included, and an amount
/// too small to print as a hundredth of a unit is printed as an upper bound
/// rather than as the zero it would round to: rounding a real cost down to
/// nothing is the one way this row can lie.
pub fn money(cost: session_state.Cost, a: Allocator) ![]const u8 {
    const sign: []const u8 = if (std.mem.eql(u8, cost.currency, "USD"))
        "$"
    else if (std.mem.eql(u8, cost.currency, "EUR"))
        "€"
    else if (std.mem.eql(u8, cost.currency, "GBP"))
        "£"
    else
        "";
    if (sign.len != 0) {
        const below = cost.amount > 0 and cost.amount < 0.005;
        return std.fmt.allocPrint(a, "{s}{s}{d:.2}", .{ if (below) "<" else "", sign, cost.amount });
    }
    // A currency this does not know keeps the code the agent named: a reader who
    // has to look a code up is still better served than by the wrong symbol.
    if (cost.currency.len != 0) return std.fmt.allocPrint(a, "{d:.2} {s}", .{ cost.amount, cost.currency });
    return std.fmt.allocPrint(a, "{d:.2}", .{cost.amount});
}

test "a usage row says the counts, the share and the cost - and drops the bar and the share before the cost" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();

    const counts: session_state.Usage = .{ .used = 42_000, .size = 200_000, .cost = .{ .amount = 1.25, .currency = "USD" } };
    const card_value = try turnCard(counts, 200, frame);
    try std.testing.expectEqualStrings("usage", card_value.status);
    // One line: the row is not a block, so the drawer draws the chip and stops.
    try std.testing.expectEqual(tool_card.Variant.plain, card_value.variant);
    try std.testing.expectEqual(@as(usize, 0), card_value.sections.len);
    try std.testing.expect(std.mem.indexOf(u8, card_value.subject, "42k/200k") != null);
    try std.testing.expect(std.mem.indexOf(u8, card_value.subject, "21%") != null);
    try std.testing.expect(std.mem.indexOf(u8, card_value.subject, "$1.25") != null);

    // The cost outlives the bar and the share: a bar is a picture of the counts
    // beside it and a share is arithmetic on them, so at a dock's width what is
    // left is the one fact the row cannot reconstruct - `42k/200k · $1.25` fits
    // where the bar and the percentage do not.
    const narrow = try row(try metrics(counts, 10, frame), 10, frame);
    try std.testing.expectEqual(@as(usize, 1), narrow.len);
    try std.testing.expectEqualStrings("42k/200k", narrow[0].text);
    const roomier = try join(try row(try metrics(counts, 18, frame), 18, frame), frame);
    try std.testing.expectEqualStrings("42k/200k · $1.25", roomier);
    // With room for everything, everything is drawn, and the bar is what a
    // narrower row gives up first.
    const whole = try join(try row(try metrics(counts, 40, frame), 40, frame), frame);
    try std.testing.expectEqualStrings("42k/200k · $1.25 · 21% · ##-----------", whole);
    const without_bar = try join(try row(try metrics(counts, 29, frame), 29, frame), frame);
    try std.testing.expectEqualStrings("42k/200k · $1.25 · 21%", without_bar);
}

test "an absent cost is omitted and a zero cost is shown" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();

    // A session that has not reported a cost has no cell to show: a blank cell
    // or a "$0.00" would claim the session is free, which nobody said.
    const unknown: session_state.Usage = .{ .used = 0, .size = 200_000, .cost = null };
    const card_value = try turnCard(unknown, 200, frame);
    try std.testing.expect(std.mem.indexOf(u8, card_value.subject, "$") == null);
    try std.testing.expect(std.mem.indexOf(u8, card_value.subject, "0/200k") != null);

    // A cost that is there and zero was reported, and telling the two apart is
    // the whole point of the cell.
    const free: session_state.Usage = .{ .used = 0, .size = 200_000, .cost = .{ .amount = 0, .currency = "USD" } };
    const zero = try turnCard(free, 200, frame);
    try std.testing.expect(std.mem.indexOf(u8, zero.subject, "$0.00") != null);

    try std.testing.expectEqualStrings("<$0.00", try money(.{ .amount = 0.002, .currency = "USD" }, frame));
    try std.testing.expectEqualStrings("€1.25", try money(.{ .amount = 1.25, .currency = "EUR" }, frame));
    try std.testing.expectEqualStrings("3.00 ZWL", try money(.{ .amount = 3, .currency = "ZWL" }, frame));
    try std.testing.expectEqualStrings("1.25", try money(.{ .amount = 1.25, .currency = "" }, frame));
}

test "a window of no tokens has no share and no gauge" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();

    // The window is what a share is a share of: without one, the count alone is
    // the honest answer, and there is no gauge to draw.
    const unknown: session_state.Usage = .{ .used = 1_000, .size = 0, .cost = null };
    const card_value = try gaugeCard(unknown, 200, frame);
    try std.testing.expectEqualStrings("1000", card_value.subject);
    try std.testing.expectEqual(tool_card.Tone.muted, card_value.tone);

    // A session at its window says so in a colour, because that is a state a
    // reader acts on.
    const filled: session_state.Usage = .{ .used = 200_000, .size = 200_000, .cost = null };
    const at_limit = try gaugeCard(filled, 200, frame);
    try std.testing.expectEqual(tool_card.Tone.warning, at_limit.tone);
    try std.testing.expect(std.mem.indexOf(u8, at_limit.subject, "100%") != null);
    try std.testing.expect(std.mem.indexOf(u8, at_limit.subject, "#") != null);
}
