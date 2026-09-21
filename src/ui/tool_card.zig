//! What a tool call is, as data: the card vocabulary, and nothing that draws.
//!
//! A tool call is not one shape. A command is a line that ran and what it
//! exited with; a file that was read is a path and, when the record carries
//! one, a line; an edit is a file and a diff; a search is a query and what it
//! found. Drawing all of them as one row of labelled fields buries the fact the
//! reader is scanning for, so a call is drawn from a `Card` and a card is built
//! by a shape that knows what that kind of call is about (`ui/tools/`).
//!
//! This module is the vocabulary those shapes and the one drawer share:
//!
//!   - `Card`, `Section`, `Span`, `Tone`: what a card is made of. A renderer
//!     answers a `Card` and never draws: the drawer owns every rectangle, so
//!     every card on screen is laid out the same way, and a shape can be read
//!     by a test that has no renderer at all.
//!   - `Status`: the state a card is drawn in - ACP's four, plus the one the
//!     lane knows and the protocol does not send.
//!   - `Builder`: the bookkeeping ten shapes would otherwise each repeat. The
//!     sections in order, the fields already spoken for, and the cap.
//!
//! It reads no clock and no frame. Nothing here allocates except into the
//! allocator it is handed, which at a draw site is a frame's arena.

const std = @import("std");
const acp = @import("../acp/tool_call.zig");
const diff = @import("diff.zig");
const highlight = @import("../editor/highlight.zig");
const theme = @import("theme.zig");
const text = @import("../core/text.zig");
const wrap = @import("wrap.zig");
const Allocator = std.mem.Allocator;

/// The colour a piece of a card is read in, named by role rather than by value:
/// the drawer resolves a tone against the theme, so a shape never names a
/// colour and a theme repaints every card with it.
///
/// The contract called the last one `error`; `error` is a Zig keyword and an
/// enum field may not be spelled with it, so the role that means "this failed"
/// is `danger` here. Nothing else about it changed.
pub const Tone = enum { plain, muted, accent, added, removed, warning, danger };

/// One run of a row, read in one tone.
pub const Span = struct { text: []const u8, tone: Tone = .plain };

/// Which end of a payload a budget keeps.
///
/// Output is read from its end: the line that says why a command failed is its
/// last one, and a preview of the first lines of a build log tells the reader
/// the least useful thing in it. A file, a list of matches, and a diff are read
/// from their start. The reference calls the two `tail` and `head` and keeps the
/// same distinction.
pub const Edge = enum { head, tail };

/// One labelled group of a card's body.
pub const Section = struct {
    /// A bar naming the section, like the reference's labelled sections. Empty
    /// for the body, which has no bar.
    label: []const u8 = "",
    /// What the section is about when the rows do not say, e.g. a path.
    detail: []const u8 = "",
    rows: []const []const Span,
    /// Which end a budget keeps, and therefore which end the marker names.
    edge: Edge = .head,
};

/// How much of a card the transcript draws around it.
///
/// A framed card owns its gutter and shows its body under the pill; a quiet one
/// is a line in the flow - the pill, the subject, and nothing else until the
/// reader opens it. This is the reference's `framed` / `plain` variant, and it
/// is what keeps three reads in a row three lines rather than three boxes: a
/// call is quiet because of what it is, and not because of when it finished.
pub const Variant = enum { framed, plain };

/// A call, as a renderer hands it over and the drawer draws it.
pub const Card = struct {
    /// The status line: the tool's own word and its state, and the glyph that
    /// carries the state without relying on colour. Composed by `statusLine`
    /// and read back by the drawer as a word, one space, and the glyph, so the
    /// two land in columns of their own.
    status: []const u8,
    /// The one line a reader scans with the card shut: path, command, query.
    subject: []const u8,
    tone: Tone,
    /// Shown under the pill, in order: a preview of each while the call is
    /// shut, and more of it - still capped - when the reader opens it.
    sections: []const Section = &.{},
    /// A diff to draw through src/ui/diff.zig when there is one.
    diff: ?[]const u8 = null,
    /// Whether the result is still arriving. A streaming card may repaint.
    partial: bool = false,
    /// How much the transcript draws around the card. See `Variant`.
    variant: Variant = .framed,
};

/// The state a card is drawn in.
///
/// ACP names four, and four are not quite enough: the protocol has one `failed`
/// for a tool that went wrong and for a call the reader cancelled, and those
/// are different things to read. The lane knows which one it is - a cancel is
/// still in flight when its calls fail - so the fifth state is derived rather
/// than invented, and nothing here claims a state nobody reported.
pub const Status = enum {
    pending,
    running,
    done,
    aborted,
    failed,

    /// The state a record is drawn in, given whether its lane is cancelling.
    pub fn of(state: acp.State, cancelling: bool) Status {
        return switch (state) {
            .pending => .pending,
            .in_progress => .running,
            .completed => .done,
            .failed => if (cancelling) .aborted else .failed,
        };
    }

    /// Whether the result is still arriving: the one state whose glyph moves.
    pub fn arriving(self: Status) bool {
        return self == .running;
    }

    /// The glyph that carries the state when the colour cannot.
    ///
    /// These are the four marks the runs panel already uses, meaning the same
    /// four things, plus the mark for a cancellation: a call the reader stopped
    /// is not a call that went wrong, and the two must not read alike. The
    /// reference resolves its symbols through the theme
    /// (`theme.styledSymbol("status.success", …)`) so a theme can restyle them;
    /// our theme carries colours and not symbols, so the table lives here with
    /// the vocabulary every shape already reads. This is the one place a
    /// theme's own symbol table would replace.
    pub fn symbol(self: Status) []const u8 {
        return switch (self) {
            .pending => "○",
            .running => "●",
            .done => "✓",
            .aborted => "⊘",
            .failed => "✗",
        };
    }

    /// The tone the card is drawn in, which is the reference's rule carried by
    /// one colour: work that is still moving is the accent, work that has
    /// settled recedes to the dim role, a cancellation is a warning, and a
    /// failure is an error. A settled call stops competing for the reader's
    /// attention, which is the whole point of drawing the state at all.
    pub fn tone(self: Status) Tone {
        return switch (self) {
            .pending, .running => .accent,
            .done => .muted,
            .aborted => .warning,
            .failed => .danger,
        };
    }
};

/// The frames a running card's glyph moves through, so a long call does not
/// look frozen. ASCII on purpose, and the same four frames `ui/activity.zig`
/// uses for the lane's indicator: the atlas covers what the system font has,
/// and a braille spinner would be a gamble on that font rather than a decision
/// about what to show.
pub const spinner = "|/-\\";

/// The frame of the spinner a call in flight shows.
pub fn spin(frame: usize) []const u8 {
    return spinner[frame % spinner.len ..][0..1];
}

/// The tool's own word for a kind. A reader learns ten words once and then
/// scans them, which a bracket full of JSON never gave them.
pub fn kindWord(kind: acp.Kind) []const u8 {
    return switch (kind) {
        .read => "read",
        .edit => "edit",
        .delete => "delete",
        .move => "move",
        .search => "search",
        .execute => "run",
        .think => "think",
        .fetch => "fetch",
        .switch_mode => "mode",
        .other => "tool",
    };
}

/// The status line a card carries: the kind's word, a space, and the state's
/// glyph.
pub fn statusLine(a: Allocator, kind: acp.Kind, status: Status) ![]const u8 {
    return std.fmt.allocPrint(a, "{s} {s}", .{ kindWord(kind), status.symbol() });
}

/// The two halves of a status line, as the drawer reads them back: the word,
/// and what follows the last space. A status with no space is all word, because
/// a glyph is not something a guessed split can invent.
pub const StatusLine = struct { word: []const u8, mark: []const u8 };

pub fn splitStatus(status: []const u8) StatusLine {
    const space = std.mem.lastIndexOfScalar(u8, status, ' ') orelse return .{ .word = status, .mark = "" };
    return .{ .word = status[0..space], .mark = status[space + 1 ..] };
}

/// The row budgets a call's body is drawn with.
///
/// Expanding a call has to show the reader something it did not already have,
/// so a budget is a function of the state rather than one constant: a shut card
/// shows a preview of each section, an open one shows several times that, and
/// past *that* the honest answer is the marker rather than the whole payload.
/// The reference uses 3 rows for a collapsed output or list and 10-12 for an
/// expanded one; our agent dock is about 44 columns wide, where a line wraps
/// sooner and the panel is shorter, so an expanded section gets 10 rows and a
/// diff gets 40. These are the numbers to change, and they are here rather than
/// scattered through the drawing.
pub const Rows = struct {
    /// Rows of a section a shut call shows.
    pub const preview: usize = 3;
    /// Rows of a section an open call shows.
    pub const expanded: usize = 10;
    /// Rows of a diff a shut call shows: a few more than an output preview,
    /// because a diff's first lines are the ones that say what changed.
    pub const diff_preview: usize = 8;
    /// Rows of a diff an open call shows. A megabyte of diff is not something
    /// the panel can show, and the count in the marker is the honest answer.
    pub const diff_expanded: usize = 40;

    /// The rows of a section a card in this state shows. It is a decision about
    /// the card rather than about the drawing, which is why it lives here: the
    /// drawer asks it and a test can read it without one.
    pub fn cap(open: bool) usize {
        return if (open) expanded else preview;
    }

    /// The rows of a diff a card in this state shows.
    pub fn diffCap(open: bool) usize {
        return if (open) diff_expanded else diff_preview;
    }
};

/// What a cap left of a payload.
pub const Trim = struct { shown: usize, dropped: usize };

/// Cap `total` rows at `cap`: what is drawn, and what the marker names. The
/// marker takes a row of its own, so a payload past the cap shows one row fewer
/// than the cap rather than a row more.
pub fn trim(total: usize, cap: usize) Trim {
    if (total <= cap) return .{ .shown = total, .dropped = 0 };
    const shown = cap -| 1;
    return .{ .shown = shown, .dropped = total - shown };
}

/// The words a capped payload ends with - or, for a payload whose tail is kept,
/// begins with: how much was left out and which end it went from, because a
/// reader told "more" and a reader told "above" are missing different things.
/// While the reader can still do something about it, the key that reveals the
/// rest is named too; an open call has nothing more to give and says nothing.
pub fn moreText(a: Allocator, dropped: usize, hint: bool, edge: Edge) ![]const u8 {
    const words = switch (edge) {
        .head => try std.fmt.allocPrint(a, "… {d} more lines", .{dropped}),
        .tail => try std.fmt.allocPrint(a, "… {d} lines above", .{dropped}),
    };
    if (!hint) return words;
    return std.fmt.allocPrint(a, "{s} (ctrl+o to expand)", .{words});
}

/// The summary a shape hands back: the verb the lane is doing, and the one
/// value it is doing it to. This is the reference's `activitySummary`, and it
/// is why the lane's line can say "reading src/app.zig" without knowing what a
/// card is.
pub const Summary = struct { label: []const u8, detail: []const u8 };

pub fn summary(label: []const u8, detail: []const u8) Summary {
    return .{ .label = label, .detail = detail };
}

/// What a call is about, from the fields the record carries and then from the
/// subject it read out of them. A shape says what its call is about, and says
/// less rather than guessing when the record is quiet.
pub fn about(call: acp.ToolCall, labels: []const []const u8) []const u8 {
    if (fieldValue(call, labels)) |value| if (value.len != 0) return value;
    if (call.subject.len != 0) return call.subject;
    return call.title;
}

/// The value of the first of `labels` the record carries, or null when it
/// carries none of them.
pub fn fieldValue(call: acp.ToolCall, labels: []const []const u8) ?[]const u8 {
    for (labels) |label| {
        for (call.fields) |field| {
            if (std.mem.eql(u8, field.label, label)) return field.value;
        }
    }
    return null;
}

/// `bytes` as one line.
///
/// A status line, a subject, and a section bar are one row each, and a value
/// carrying a newline would draw itself a second row and break the block around
/// it - which is why the reference flattens every fragment before it joins a
/// header, and why this is done where a line is composed rather than where a
/// value is produced: a multi-line command is still a multi-line command in the
/// field it arrived in. Runs of whitespace become one space.
///
/// The answer is `bytes` itself when there is nothing to change, which is the
/// common case and costs no allocation.
pub fn flatten(a: Allocator, bytes: []const u8) ![]const u8 {
    if (!needsFlattening(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var space = false;
    for (bytes) |byte| {
        switch (byte) {
            ' ', '\t', '\n', '\r' => space = out.items.len != 0,
            else => {
                if (space) try out.append(a, ' ');
                space = false;
                try out.append(a, byte);
            },
        }
    }
    return out.toOwnedSlice(a);
}

/// Whether there is anything in `bytes` a single row would have to change: a
/// line ending, a tab, or a space at either end or doubled.
fn needsFlattening(bytes: []const u8) bool {
    var space = false;
    for (bytes, 0..) |byte, index| {
        switch (byte) {
            ' ' => {
                if (space or index == 0 or index + 1 == bytes.len) return true;
                space = true;
            },
            '\t', '\n', '\r' => return true,
            else => space = false,
        }
    }
    return false;
}

/// A section naming a call's diff, with the stats a reader scans for: `+N -M`,
/// counted from the diff itself. A diff the parser cannot read gets the bar and
/// no stats, because a count that was guessed is worse than no count.
pub fn diffBar(b: *Builder, call: acp.ToolCall, label: []const u8) !void {
    const bytes = call.diff orelse return;
    const files = diff.parse(b.a, bytes) catch null;
    defer if (files) |parsed| diff.deinit(parsed, b.a);
    const detail = if (files) |parsed| try stats(b.a, parsed) else "";
    try b.bar(label, detail);
}

/// `+N -M` for a parsed diff, or empty when it has nothing added or removed.
fn stats(a: Allocator, files: []const diff.File) ![]const u8 {
    var added: usize = 0;
    var removed: usize = 0;
    for (files) |f| {
        for (f.hunks) |hunk| {
            for (hunk.lines) |line| switch (line.kind) {
                .added => added += 1,
                .removed => removed += 1,
                else => {},
            };
        }
    }
    if (added == 0 and removed == 0) return "";
    return std.fmt.allocPrint(a, "+{d} -{d}", .{ added, removed });
}

/// The cells a wrapped continuation steps in by, so a wrapped row reads as the
/// row above it continued. The drawer indents by the same amount, which is why
/// it lives here with the plan.
pub const hang_cells: usize = 2;

/// A section's payload, planned: the rows to draw and the lines the budget left
/// out.
///
/// Two measures meet here and they are different on purpose. The budget is
/// spent in *display rows*, because that is what the panel pays for, and it is
/// spent only on what is drawn: the walk measures one row at a time and stops
/// as soon as the budget cannot take the next one whole, so a shut card never
/// lays out a body it is not going to draw. What the marker names is *lines* -
/// the rows the card already holds, one per line, with no layout at all.
pub const Plan = struct {
    /// One row of the payload, as it will be drawn.
    pub const Step = struct {
        /// The row of the section this came from, which is where its tones are.
        line: usize,
        /// The text the pieces are slices of. Empty for a row drawn cut, whose
        /// piece is not part of it.
        bytes: []const u8,
        /// One entry per display row.
        pieces: []const []const u8,
        /// Whether the row was cut rather than wrapped, which is what a single
        /// row longer than the whole budget comes to: a panel that showed
        /// nothing but `… 1 more lines` would have shown the reader nothing.
        cut: bool,
    };

    steps: []const Step,
    /// Lines the budget left out, which is what the marker names.
    withheld: usize,

    /// The display rows the payload takes.
    pub fn rows(self: Plan) usize {
        var total: usize = 0;
        for (self.steps) |step| total += step.pieces.len;
        return total;
    }

    /// The rows the payload and its marker take together.
    pub fn height(self: Plan) usize {
        return self.rows() + @intFromBool(self.withheld > 0);
    }
};

/// Plan a section's payload at this width.
///
/// The walk is in from the end the payload is read from: a payload whose end is
/// kept shows its last rows, and one read from the front shows its first, so
/// the answer is a window either way and the rows come out in reading order
/// whichever end chose them.
pub fn plan(a: Allocator, section: Section, columns: usize, expanded: bool) !Plan {
    const budget = Rows.cap(expanded);
    const lines = section.rows.len;
    const room = columns -| hang_cells;

    var pieces: std.ArrayList([]const u8) = .empty;
    var shown: usize = 0;
    var used: usize = 0;
    var cut: ?[]const u8 = null;
    while (shown < lines) {
        const line = readFrom(section, lines, shown);
        const bytes = try joined(a, section.rows[line]);
        pieces.clearRetainingCapacity();
        try wrap.spans(a, bytes, room, &pieces);
        // The marker takes one of the budget's rows when anything is left over,
        // so the payload spends one fewer than the budget rather than one more.
        const spare: usize = @intFromBool(shown + 1 < lines);
        const room_rows = budget -| spare;
        if (used > 0 and used + pieces.items.len > room_rows) break;
        if (used == 0 and pieces.items.len > room_rows) {
            // One row, longer than the whole budget: drawn cut, with an
            // ellipsis, and the buffer kept for the plan.
            const buffer = try a.alloc(u8, bytes.len + 3);
            cut = switch (section.edge) {
                .head => wrap.elide(buffer, bytes, room),
                .tail => try elideStart(buffer, bytes, room),
            };
            used += 1;
        } else {
            used += pieces.items.len;
        }
        shown += 1;
        if (used >= budget) break;
    }

    // The window, written out in reading order: rows are drawn top to bottom
    // whichever end they were chosen from.
    const first = if (section.edge == .tail) lines - shown else 0;
    var steps: std.ArrayList(Plan.Step) = .empty;
    for (0..shown) |offset| {
        const line = first + offset;
        const bytes = try joined(a, section.rows[line]);
        if (cut) |elided| {
            // The cut row is the one the walk reached first, which is the first
            // step of a head-kept payload and the last of a tail-kept one.
            const is_cut = (section.edge == .head and offset == 0) or (section.edge == .tail and offset + 1 == shown);
            if (is_cut) {
                try steps.append(a, .{ .line = line, .bytes = "", .pieces = try a.dupe([]const u8, &.{elided}), .cut = true });
                continue;
            }
        }
        var wrapped: std.ArrayList([]const u8) = .empty;
        try wrap.spans(a, bytes, room, &wrapped);
        try steps.append(a, .{ .line = line, .bytes = bytes, .pieces = try wrapped.toOwnedSlice(a), .cut = false });
    }
    return .{ .steps = try steps.toOwnedSlice(a), .withheld = lines - shown };
}

/// The row a payload reads at `position` from its kept end.
fn readFrom(section: Section, lines: usize, position: usize) usize {
    return if (section.edge == .tail) lines - 1 - position else position;
}

/// `bytes` shortened to its end, with an ellipsis where the beginning was. The
/// mirror of `wrap.elide`, for a line whose end is the part that matters.
fn elideStart(buffer: []u8, bytes: []const u8, columns: usize) ![]const u8 {
    const width = @max(1, columns);
    const cells = cellCount(bytes);
    if (cells <= width) return bytes;
    const kept = width - 1;
    var index: usize = bytes.len;
    var taken: usize = 0;
    while (taken < kept and index > 0) : (taken += 1) index = text.previous(bytes, index);
    const slice = buffer[0..@min(buffer.len, 3 + bytes.len - index)];
    @memcpy(slice[0..3], "…");
    @memcpy(slice[3..], bytes[index..]);
    return slice;
}

/// The cells a string holds, which is what an elision counts in.
fn cellCount(bytes: []const u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) : (at = text.next(bytes, at)) count += 1;
    return count;
}

/// A row's spans as the one text they are wrapped as. A row of one span is
/// already that text; a row of several is joined, because where a line breaks
/// is a property of the sentence and not of the colour it is written in.
fn joined(a: Allocator, line: []const Span) ![]const u8 {
    if (line.len == 0) return "";
    if (line.len == 1) return line[0].text;
    var bytes: std.ArrayList(u8) = .empty;
    for (line) |span| try bytes.appendSlice(a, span.text);
    return bytes.toOwnedSlice(a);
}

/// A byte range of a line: a wrapped piece of it, or one of the runs it is
/// drawn in.
pub const Stretch = struct { from: usize, to: usize };

/// Which part of a run a piece covers, or null when the two do not meet.
///
/// A piece is a stretch of a line and a run is a stretch of the same line, and
/// the caller walks the runs in order. A run that begins *after* the piece ends
/// - which is what a changed line produces when the mark is near its end and the
/// line breaks across display rows - must come back as "no overlap" rather than
/// being measured against it: the obvious subtraction of the piece's end from
/// the run's start is an integer underflow, and it is a panic in a debug build.
pub fn overlap(piece: Stretch, run: Stretch) ?Stretch {
    const from = @max(piece.from, run.from);
    const to = @min(piece.to, run.to);
    if (to <= from) return null;
    return .{ .from = from - run.from, .to = to - run.from };
}

/// A diff planned the same way: the rows the budget shows, and the diff's lines
/// it leaves out. The two measures are the section's two measures, for the same
/// reason.
pub const DiffPlan = struct {
    /// One run of a diff line: the text, and the colour it is drawn in.
    ///
    /// A line is one run when nothing more is known about it than its kind; a
    /// context line is one run per syntax token, because it is code with no
    /// change in it and drawing it flat next to marked lines reads as
    /// half-rendered; and a line whose words are marked is one run per word,
    /// because the mark is what the reader is looking for.
    pub const Run = struct {
        text: []const u8,
        colour: theme.Color,
        /// A word that differs from the line this one pairs with, which the
        /// drawer marks rather than only colours.
        marked: bool = false,
    };

    pub const Step = struct {
        /// The line as the diff wrote it.
        text: []const u8,
        /// The runs the line is drawn in, in order, covering it.
        runs: []const Run,
        /// One entry per display row, or one elided entry for a path or a line
        /// drawn cut: a path is a name rather than a paragraph, and it is cut
        /// like every other name in this interface.
        pieces: []const []const u8,
        /// Whether the line was drawn cut rather than wrapped, in which case
        /// its one piece is an elided copy rather than a slice of `text`.
        cut: bool = false,
    };

    steps: []const Step,
    /// Lines the budget left out, which is what the marker names.
    withheld: usize,

    pub fn rows(self: DiffPlan) usize {
        var total: usize = 0;
        for (self.steps) |step| total += step.pieces.len;
        return total;
    }

    pub fn height(self: DiffPlan) usize {
        return self.rows() + @intFromBool(self.withheld > 0);
    }
};

/// Plan a diff at this width. `files` is null when the bytes did not read as a
/// diff, in which case they are planned as the lines they were written in.
///
/// The budget is spent the same way a section's is, and for the same reason: a
/// line is taken whole or left out, so the drawn rows can never run past the
/// budget the way a long line taken whole would. What cannot happen is a line
/// skipped and a shorter one after it drawn - the diff is read in order, so the
/// first line that does not fit ends it.
pub fn planDiff(a: Allocator, files: ?[]const diff.File, bytes: []const u8, columns: usize, expanded: bool) !DiffPlan {
    const budget = Rows.diffCap(expanded);
    const first = try walkDiff(a, files, bytes, columns, budget);
    // The marker takes one of the budget's rows when anything was left out, so
    // a payload that is cut spends one fewer than the budget rather than one
    // more.
    if (first.withheld == 0 or budget < 2) return first;
    return walkDiff(a, files, bytes, columns, budget - 1);
}

fn walkDiff(a: Allocator, files: ?[]const diff.File, bytes: []const u8, columns: usize, budget: usize) !DiffPlan {
    const room = columns -| hang_cells;
    var steps: std.ArrayList(DiffPlan.Step) = .empty;
    var total: usize = 0;
    var rows: usize = 0;
    var stopped = false;

    if (files) |parsed| {
        for (parsed) |file| {
            // The lines of a file are read as the language that file is written
            // in, with the editor's own scanner, so a diff of Zig is coloured
            // by the rules Zig is coloured by and the two cannot drift apart.
            var scanner: highlight.Scanner = .{ .language = highlight.Language.detect(file.path) };
            // Removed lines waiting for the added lines that replaced them. The
            // pairing is positional, which is what a diff's own order means: the
            // first removed line goes with the first added one after it.
            var waiting: std.ArrayList(usize) = .empty;
            if (file.path.len > 0) {
                total += 1;
                if (rows < budget) {
                    const buffer = try a.alloc(u8, file.path.len + 3);
                    try steps.append(a, .{
                        .text = file.path,
                        .runs = try plainRuns(a, file.path, theme.muted),
                        .pieces = try a.dupe([]const u8, &.{wrap.elide(buffer, file.path, columns)}),
                    });
                    rows += 1;
                }
            }
            for (file.hunks) |hunk| {
                total += 1;
                waiting.clearRetainingCapacity();
                if (!stopped) {
                    if (try take(a, hunk.header, try plainRuns(a, hunk.header, theme.accent), room, budget, rows)) |step| {
                        try steps.append(a, step);
                        rows += step.pieces.len;
                    } else stopped = true;
                }
                for (hunk.lines) |line| {
                    total += 1;
                    if (stopped) continue;
                    if (line.kind == .added and waiting.items.len > 0) {
                        // The added line that replaces the first removed line
                        // still waiting, marked word by word. The pairing is
                        // the diff's own order rather than a judgement about
                        // how alike the two lines are, and `wordDiff` is what
                        // decides whether they share enough to be marked at
                        // all - two lines that share almost nothing are two
                        // whole lines and stay that way.
                        const index = waiting.orderedRemove(0);
                        const partner = steps.items[index];
                        const marks = try diff.wordDiff(a, partner.text[1..], line.text[1..]);
                        const added = if (marks) |both|
                            try markedRuns(a, line.text, theme.added, both.added)
                        else
                            try plainRuns(a, line.text, theme.added);
                        const step = (try take(a, line.text, added, room, budget, rows)) orelse {
                            stopped = true;
                            continue;
                        };
                        // Both sides of a pair carry their marks: one line of a
                        // pair marked and the other plain reads as two
                        // unrelated lines.
                        if (marks) |both| steps.items[index].runs = try markedRuns(a, partner.text, theme.removed, both.removed);
                        try steps.append(a, step);
                        rows += step.pieces.len;
                        continue;
                    }
                    if (line.kind == .removed) {
                        const runs = try plainRuns(a, line.text, theme.removed);
                        const step = (try take(a, line.text, runs, room, budget, rows)) orelse {
                            stopped = true;
                            continue;
                        };
                        try steps.append(a, step);
                        try waiting.append(a, steps.items.len - 1);
                        rows += step.pieces.len;
                        continue;
                    }
                    waiting.clearRetainingCapacity();
                    const runs = try runsFor(a, &scanner, line);
                    const step = (try take(a, line.text, runs, room, budget, rows)) orelse {
                        stopped = true;
                        continue;
                    };
                    try steps.append(a, step);
                    rows += step.pieces.len;
                }
            }
        }
        const drawn = steps.items.len;
        return .{ .steps = try steps.toOwnedSlice(a), .withheld = total - drawn };
    }
    var scanner: highlight.Scanner = .{ .language = .plain };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        total += 1;
        if (stopped) continue;
        const runs = try runsFor(a, &scanner, .{ .kind = .context, .text = line });
        const step = (try take(a, line, runs, room, budget, rows)) orelse {
            stopped = true;
            continue;
        };
        try steps.append(a, step);
        rows += step.pieces.len;
    }
    const drawn = steps.items.len;
    return .{ .steps = try steps.toOwnedSlice(a), .withheld = total - drawn };
}

/// The runs a line is drawn in, advancing the scanner the way the editor does:
/// every line of a file is read, in order, because a block comment or an open
/// string carries from one line to the next.
fn runsFor(a: Allocator, scanner: *highlight.Scanner, line: diff.Line) ![]const DiffPlan.Run {
    switch (line.kind) {
        // A context line is code with nothing changed in it, so it is read as
        // the code it is - which is what keeps a diff from looking
        // half-rendered next to a line whose words are marked.
        .context => return try syntaxRuns(a, scanner, line.text),
        .added, .removed => {
            scanner.scanLine(line.text);
            scanner.endLine();
            const base = if (line.kind == .added) theme.added else theme.removed;
            return try plainRuns(a, line.text, base);
        },
        .hunk => return try plainRuns(a, line.text, theme.accent),
        .meta => return try plainRuns(a, line.text, theme.muted),
    }
}

/// One run covering the whole line, for a line nothing more is known about.
fn plainRuns(a: Allocator, line: []const u8, colour: theme.Color) ![]const DiffPlan.Run {
    return a.dupe(DiffPlan.Run, &.{.{ .text = line, .colour = colour }});
}

/// The runs a paired line is drawn in: its prefix keeps the line's own colour,
/// and the words that differ are drawn in the reader's colour and marked. A
/// word that is the same on both sides of a pair stays the colour of the line
/// it is on, which is what makes the changed words the thing the eye finds.
fn markedRuns(a: Allocator, line: []const u8, base: theme.Color, spans: []const diff.Span) ![]const DiffPlan.Run {
    var runs: std.ArrayList(DiffPlan.Run) = .empty;
    if (line.len > 0) try runs.append(a, .{ .text = line[0..1], .colour = base });
    for (spans) |span| {
        try runs.append(a, .{
            .text = span.text,
            .colour = if (span.changed) theme.text else base,
            .marked = span.changed,
        });
    }
    return runs.toOwnedSlice(a);
}

/// A code line as the runs the scanner reads it in: one run per stretch of the
/// line that shares a colour, in order, covering the line.
fn syntaxRuns(a: Allocator, scanner: *highlight.Scanner, line: []const u8) ![]const DiffPlan.Run {
    var runs: std.ArrayList(DiffPlan.Run) = .empty;
    var start: usize = 0;
    var at: usize = 0;
    var colour: ?theme.Color = null;
    while (at < line.len) {
        const found = scanner.color(line, at);
        if (colour) |current| {
            if (!std.meta.eql(current, found)) {
                try runs.append(a, .{ .text = line[start..at], .colour = current });
                start = at;
            }
        }
        colour = found;
        at = text.next(line, at);
    }
    if (colour) |current| try runs.append(a, .{ .text = line[start..], .colour = current });
    scanner.endLine();
    return runs.toOwnedSlice(a);
}

/// Take one diff line into the plan: wrapped in the columns it has, cut to one
/// elided row when it is the first line and longer than the whole budget, or
/// null when the budget cannot take it.
fn take(a: Allocator, line: []const u8, runs: []const DiffPlan.Run, room: usize, budget: usize, rows: usize) !?DiffPlan.Step {
    var pieces: std.ArrayList([]const u8) = .empty;
    try wrap.spans(a, line, room, &pieces);
    if (rows + pieces.items.len <= budget) {
        return .{ .text = line, .runs = runs, .pieces = try pieces.toOwnedSlice(a) };
    }
    if (rows == 0) {
        // One line longer than the whole budget: drawn cut, with an ellipsis,
        // rather than replaced by a marker that shows the reader nothing.
        const buffer = try a.alloc(u8, line.len + 3);
        const shown = wrap.elide(buffer, line, room);
        return .{ .text = line, .runs = runs, .pieces = try a.dupe([]const u8, &.{shown}), .cut = true };
    }
    return null;
}

/// Building a card.
///
/// A shape says what its call is about - the file, the command, what came back
/// - and this does the bookkeeping every shape would otherwise repeat: the
/// sections in order, the fields already spoken for, and the one card at the
/// end. A field a shape has read is not repeated by `rest`, and a field nobody
/// read is still shown, which is what keeps a card from quietly dropping
/// something the agent said.
pub const Builder = struct {
    a: Allocator,
    call: acp.ToolCall,
    status: Status,
    /// How much the drawer puts around this card. A shape sets it from its own
    /// config: what a call is decides how loud it is.
    variant: Variant = .framed,
    sections: std.ArrayList(Section) = .empty,
    /// The field labels a shape has read: what `rest` leaves alone.
    claimed: std.ArrayList([]const u8) = .empty,

    pub fn init(a: Allocator, call: acp.ToolCall, status: Status) Builder {
        return .{ .a = a, .call = call, .status = status };
    }

    /// A bar naming something, with no rows under it: for a fact that is one
    /// value, like a directory or an exit code.
    pub fn bar(self: *Builder, label: []const u8, detail: []const u8) !void {
        try self.push(label, detail, &.{}, .head);
    }

    /// A line of the card's own: no bar, one row, in the dim role. This is the
    /// digest a shut card shows - what the call was given, in one row whatever
    /// the number of fields - so a reader who never opens the call is not
    /// looking at a title with nothing behind it.
    pub fn digest(self: *Builder, line: []const u8) !void {
        if (line.len == 0) return;
        const spans = try self.a.alloc(Span, 1);
        spans[0] = .{ .text = line, .tone = .muted };
        const rows = try self.a.alloc([]const Span, 1);
        rows[0] = spans;
        try self.push("", "", rows, .head);
    }

    /// A section over a payload: one row per line of it, so the drawer's cap
    /// counts the lines a reader would count. Its start is what a budget keeps -
    /// which is right for a file, a list, and a diff.
    pub fn value(self: *Builder, label: []const u8, detail: []const u8, body: []const u8) !void {
        try self.payload(label, detail, body, .head);
    }

    /// The same section for a payload that is read from its end: a command's
    /// output, where the line saying why it failed is the last one, and a
    /// preview of the first lines says the least useful thing in it.
    pub fn output(self: *Builder, label: []const u8, detail: []const u8, body: []const u8) !void {
        try self.payload(label, detail, body, .tail);
    }

    fn payload(self: *Builder, label: []const u8, detail: []const u8, body: []const u8, edge: Edge) !void {
        const trimmed = std.mem.trimEnd(u8, body, "\r\n");
        if (trimmed.len == 0) return;
        var rows: std.ArrayList([]const Span) = .empty;
        var lines = std.mem.splitScalar(u8, trimmed, '\n');
        while (lines.next()) |line| {
            const spans = try self.a.alloc(Span, 1);
            spans[0] = .{ .text = std.mem.trimEnd(u8, line, "\r") };
            try rows.append(self.a, spans);
        }
        try self.push(label, detail, try rows.toOwnedSlice(self.a), edge);
    }

    /// One field under its own label: what a call no shape knows is made of.
    pub fn field(self: *Builder, f: acp.Field) !void {
        try self.value(f.label, "", f.value);
        try self.claimed.append(self.a, f.label);
    }

    /// Every field nobody has read, under its own label.
    pub fn rest(self: *Builder) !void {
        for (self.call.fields, 0..) |f, index| {
            // A claimed label is skipped once, not for every field carrying it:
            // two locations are two lines, and the second is still news.
            if (self.spoken(f.label) and self.isFirstWithLabel(index)) continue;
            try self.field(f);
        }
    }

    /// Read the first of `labels` the record carries, and claim the label it
    /// matched: a value the card shows somewhere else is not shown twice.
    pub fn take(self: *Builder, labels: []const []const u8) !?[]const u8 {
        for (labels) |label| {
            const found = fieldValue(self.call, &.{label}) orelse continue;
            if (found.len == 0) continue;
            try self.claimed.append(self.a, label);
            return found;
        }
        return null;
    }

    /// Whether a field's label has been read already.
    pub fn spoken(self: *const Builder, label: []const u8) bool {
        for (self.claimed.items) |claimed| {
            if (std.mem.eql(u8, claimed, label)) return true;
        }
        return false;
    }

    /// The card the drawer draws. The status line and the subject are composed
    /// here rather than by each shape, because both are one row and both are
    /// flattened: a value with a newline in it would otherwise draw a second
    /// row and break the block it sits in.
    pub fn finish(self: *Builder, subject: []const u8, diff_bytes: ?[]const u8) !Card {
        return .{
            .status = try statusLine(self.a, self.call.kind, self.status),
            .subject = try flatten(self.a, subject),
            .tone = self.status.tone(),
            .sections = try self.sections.toOwnedSlice(self.a),
            .diff = diff_bytes,
            .partial = self.status.arriving(),
            // A quiet call is quiet because of what it is - a file that was
            // read, a thought. A failure is never quiet: a call the reader has
            // to open to notice is one that gets missed, which is the rule the
            // transcript already had for a failed call arriving open.
            .variant = if (self.status == .failed or self.status == .aborted) .framed else self.variant,
        };
    }

    fn push(self: *Builder, label: []const u8, detail: []const u8, rows: []const []const Span, edge: Edge) !void {
        try self.sections.append(self.a, .{
            .label = try flatten(self.a, label),
            .detail = try flatten(self.a, detail),
            .rows = rows,
            .edge = edge,
        });
    }

    /// Whether `index` is the first field in the call with that label, which is
    /// the field a shape's `take` read.
    fn isFirstWithLabel(self: *const Builder, index: usize) bool {
        const label = self.call.fields[index].label;
        for (self.call.fields[0..index]) |other| {
            if (std.mem.eql(u8, other.label, label)) return false;
        }
        return true;
    }
};
