//! One tool call, as the transcript draws it: whatever card a renderer built,
//! turned into pixels.
//!
//! A call is not prose, and it is not one shape either: what a `read` is worth
//! drawing and what a failing command is worth drawing are different, and the
//! difference is decided in `ui/tools/`. This module is the other half of that
//! split, and it is only pixels: every rectangle, every column, every elision.
//! What a section holds, how much of it a budget shows, and which lines the
//! marker names are decided in `ui/tool_card.zig`, so a shape can be read - and
//! a plan can be checked - by a test with no renderer in it.
//!
//! `rows` says how many display rows a card takes and `draw` fills them; both
//! walk the same plan - the pill, the sections, the diff - so a card can never
//! be sized for one arrangement and drawn in another.
//!
//! Nothing here owns the call: the card comes from the frame's arena, and every
//! slice in it is borrowed for as long as the frame is.

const std = @import("std");
const acp = @import("../acp/tool_call.zig");
const diff = @import("diff.zig");
const theme = @import("theme.zig");
const wrap = @import("wrap.zig");
const tool_card = @import("tool_card.zig");
const text = @import("../core/text.zig");
const Renderer = @import("../gpu/renderer.zig").Renderer;
const Rect = @import("layout.zig").Rect;
const Allocator = std.mem.Allocator;

/// Where a block's first row starts.
pub const Vec2 = struct { x: f32, y: f32 };

/// What a block is measured in. The transcript lays text out in cells, so a
/// chip is as wide as the cells it holds however wide the glyphs under them
/// happen to be drawn.
pub const Metrics = struct { advance: f32 };

/// The pad inside the pill, and the space after it before the subject: enough
/// that the pill reads as an object with the subject beside it, rather than as
/// a word with brackets around it.
const chip_pad: f32 = 7;
const chip_gap: f32 = 8;

/// How far the pill is inset from the row it sits in. A pill that filled the
/// row would be a bar.
const pill_inset: f32 = 3;

/// The gutter down a card's left edge: one column of the panel, and a bar two
/// device pixels wide inside it, which is what the transcript's other rails
/// (a quotation, a run) are drawn with. The reference frames a block in a
/// rounded box; that costs two columns and a border between every call, and our
/// agent dock is about 44 columns wide, so the frame here is the one column the
/// information actually needs.
const gutter_cells: usize = 1;
const gutter_width: f32 = 2;

/// The columns a section bar keeps for its rule, and the gap between the label
/// and the detail beside it.
const bar_rule_cells: usize = 3;
const bar_gap_cells: usize = 2;

/// How many display rows a card takes at this width: the pill's own row, then
/// the sections and the diff. A caller that lays out rows asks this; the height
/// in pixels is this times the line height. The allocator is the frame's: the
/// plans are built in it.
pub fn rows(a: Allocator, card: tool_card.Card, width: f32, expanded: bool, metrics: Metrics) !usize {
    const columns = contentColumns(card, width, metrics);
    var count: usize = 1;
    for (card.sections) |section| {
        if (!shows(section, card, expanded)) continue;
        const plan = try tool_card.plan(a, section, columns, expanded);
        count += @intFromBool(section.label.len > 0) + plan.height();
    }
    if (!frames(card, expanded)) return count;
    if (card.diff) |bytes| {
        // A diff the reader will not get out of the parser is text, and is
        // planned as the text it is drawn as.
        const files = diff.parse(a, bytes) catch null;
        defer if (files) |parsed| diff.deinit(parsed, a);
        const plan = try tool_card.planDiff(a, files, bytes, columns, expanded);
        // One blank row between the sections and the diff, so the two are not
        // read as one list.
        if (plan.rows() > 0) count += 1 + plan.height();
    }
    return count;
}

/// Whether a card's structure - its barred sections and its diff - is on
/// screen: a framed card shows it under the pill, a quiet one keeps it for the
/// reader who opens it.
fn frames(card: tool_card.Card, expanded: bool) bool {
    return expanded or card.variant == .framed;
}

/// Whether a section is drawn. One with no bar is a line of the card's own
/// scan - the digest of what a call was given - and is drawn whenever the card
/// is; a barred section is structure, and follows the card's variant.
fn shows(section: tool_card.Section, card: tool_card.Card, expanded: bool) bool {
    return section.label.len == 0 or frames(card, expanded);
}

/// Draw the card at `origin`. The caller owns the clip; the card starts on the
/// row grid `rows` counted and never leaves it. `frame` is the counter the one
/// moving glyph is drawn from, so a call in flight does not look frozen.
pub fn draw(card: tool_card.Card, r: *Renderer, origin: Vec2, width: f32, line_height: f32, expanded: bool, metrics: Metrics, frame: usize, a: Allocator) !void {
    const framed = card.variant == .framed;
    const columns = contentColumns(card, width, metrics);
    const x = origin.x + if (framed) @as(f32, @floatFromInt(gutter_cells)) * metrics.advance else 0;
    const colour = toneColor(card.tone);

    // The gutter runs down the card's left edge in the colour its state is read
    // in, and only a framed card has one: a quiet call is a line in the flow,
    // and three of them in a row are three lines rather than three boxes.
    if (framed) try drawGutter(r, origin.x, origin.y, line_height, colour);
    try drawChip(card, r, .{ .x = x, .y = origin.y }, columns, line_height, metrics, frame, a);

    var row: usize = 1;
    for (card.sections) |section| {
        if (!shows(section, card, expanded)) continue;
        const plan = try tool_card.plan(a, section, columns, expanded);
        const height = @intFromBool(section.label.len > 0) + plan.height();
        if (height == 0) continue;
        if (framed) try drawGutter(r, origin.x, origin.y + lineY(row, line_height), @as(f32, @floatFromInt(height)) * line_height, colour);
        _ = try drawSection(section, plan, r, x, origin.y + lineY(row, line_height), line_height, columns, metrics, expanded, a);
        row += height;
    }

    if (!frames(card, expanded)) return;
    const bytes = card.diff orelse return;
    const files = diff.parse(a, bytes) catch null;
    defer if (files) |parsed| diff.deinit(parsed, a);
    const plan = try tool_card.planDiff(a, files, bytes, columns, expanded);
    if (plan.rows() == 0) return;
    row += 1;
    const height = 1 + plan.height();
    try drawGutter(r, origin.x, origin.y + lineY(row - 1, line_height), @as(f32, @floatFromInt(height)) * line_height, colour);
    try drawDiff(plan, r, x, origin.y + lineY(row, line_height), line_height, metrics);
    row += plan.rows();
    if (plan.withheld > 0) {
        const marker = try moreRow(a, plan.withheld, !expanded, .head);
        try drawText(marker, r, x, origin.y + lineY(row, line_height));
    }
}

/// The row a capped payload ends - or, for a payload whose tail is kept,
/// begins - with. Exported because the number it names and the direction it
/// names are the whole point of a cap, and a test can read it without a
/// renderer.
pub fn moreRow(a: Allocator, dropped: usize, hint: bool, edge: tool_card.Edge) !tool_card.Span {
    return .{ .text = try tool_card.moreText(a, dropped, hint, edge), .tone = .muted };
}

/// The colour a tone is drawn in. These are the roles the rest of the
/// transcript reads in, so a card, a heading and a fenced diff are the same
/// voice.
pub fn toneColor(tone: tool_card.Tone) theme.Color {
    return switch (tone) {
        .plain => theme.text,
        .muted => theme.muted,
        .accent => theme.accent,
        .added => theme.added,
        .removed => theme.removed,
        .warning => theme.amber,
        .danger => theme.red,
    };
}

/// The colour a diff line is read in - the same roles the transcript's fenced
/// diffs use, so a diff that arrived with a call and one written in prose are
/// read the same way.
pub fn diffColor(kind: diff.LineKind) theme.Color {
    return switch (kind) {
        .added => theme.added,
        .removed => theme.removed,
        .hunk => theme.accent,
        .meta => theme.muted,
        .context => theme.text,
    };
}

/// The pill: the card's status line, drawn as the tool's word and the state's
/// glyph, then the subject, cut to what is left of the row.
///
/// The two halves of the status land in columns of their own - the glyph starts
/// at the word's column plus a space - so two chips of one kind keep their marks
/// in one column, and so a glyph that moves does not walk the word around.
fn drawChip(card: tool_card.Card, r: *Renderer, origin: Vec2, columns: usize, line_height: f32, metrics: Metrics, frame: usize, a: Allocator) !void {
    // Flattened here as well as where the card was composed: this is a row, and
    // a status line carrying a newline would draw itself a second one.
    const status = tool_card.splitStatus(try tool_card.flatten(a, card.status));
    // A call whose result is still arriving shows a frame of the spinner in the
    // glyph's cell: a call that never moves reads as a frozen one.
    const mark = if (card.partial) tool_card.spin(frame) else status.mark;
    const colour = toneColor(card.tone);
    const cells = cellCount(status.word) + if (mark.len == 0) 0 else 1 + cellCount(mark);
    const pill: Rect = .{
        .x = origin.x,
        .y = origin.y + pill_inset,
        .w = @as(f32, @floatFromInt(cells)) * metrics.advance + chip_pad * 2,
        .h = @max(1, line_height - pill_inset * 2),
    };
    try r.rect(pill, theme.raised);
    _ = try drawRun(r, origin.x + chip_pad, origin.y, status.word, colour);
    if (mark.len != 0) {
        _ = try drawRun(r, origin.x + chip_pad + @as(f32, @floatFromInt(cellCount(status.word) + 1)) * metrics.advance, origin.y, mark, colour);
    }

    // The subject is one line: a path or a command is scanned rather than read,
    // and a chip that wraps is a chip whose neighbours move.
    const room = columns -| (cells + 3);
    if (room == 0 or card.subject.len == 0) return;
    const buffer = try a.alloc(u8, card.subject.len + 3);
    try r.text(pill.x + pill.w + chip_gap, origin.y, wrap.elide(buffer, card.subject, room), theme.text);
}

/// One section: its bar, the rows its plan keeps, and the row that names what
/// the budget left out. Answers how many rows it took, which is what the gutter
/// behind it is drawn from.
fn drawSection(section: tool_card.Section, plan: tool_card.Plan, r: *Renderer, x: f32, y: f32, line_height: f32, columns: usize, metrics: Metrics, expanded: bool, a: Allocator) !usize {
    var row: usize = 0;
    if (section.label.len > 0) {
        try drawBar(section, r, x, y, line_height, columns, metrics, a);
        row = 1;
    }
    // A payload whose end is kept says what it is missing above its rows: that
    // is where the missing lines were, and a marker under them would read as
    // the end of the payload rather than as the hole in front of it.
    if (plan.withheld > 0 and section.edge == .tail) {
        const marker = try moreRow(a, plan.withheld, !expanded, section.edge);
        try drawText(marker, r, x, y + lineY(row, line_height));
        row += 1;
    }
    for (plan.steps) |step| {
        row += try drawStep(section, step, r, x, y + lineY(row, line_height), line_height, metrics);
    }
    if (plan.withheld > 0 and section.edge == .head) {
        const marker = try moreRow(a, plan.withheld, !expanded, section.edge);
        try drawText(marker, r, x, y + lineY(row, line_height));
        row += 1;
    }
    return row;
}

/// One row of a section's plan: its display rows, each drawn from the pieces
/// the plan already wrapped - nothing is wrapped twice, and nothing is wrapped
/// that is not drawn.
fn drawStep(section: tool_card.Section, step: tool_card.Plan.Step, r: *Renderer, x: f32, y: f32, line_height: f32, metrics: Metrics) !usize {
    const line = section.rows[step.line];
    const hang = @as(f32, @floatFromInt(tool_card.hang_cells)) * metrics.advance;
    if (step.cut) {
        // A row longer than the whole budget: one row, its text cut, drawn in
        // the tone of the row's first run.
        const tone = if (line.len > 0) line[0].tone else .plain;
        try r.text(x, y, step.pieces[0], toneColor(tone));
        return 1;
    }
    for (step.pieces, 0..) |piece, index| {
        try drawPiece(line, step.bytes, piece, r, x + if (index == 0) 0 else hang, y + lineY(index, line_height));
    }
    return step.pieces.len;
}

/// One wrapped line of a row, drawn in the tone of the span it came from. A
/// line that straddles two spans is drawn as the pieces it is, so a label in
/// front of a value keeps its own colour and its own text.
fn drawPiece(line: []const tool_card.Span, bytes: []const u8, piece: []const u8, r: *Renderer, x: f32, y: f32) !void {
    const start = @intFromPtr(piece.ptr) - @intFromPtr(bytes.ptr);
    const end = start + piece.len;
    var pen = x;
    var at: usize = 0;
    for (line) |span| {
        const from = @max(start, at) - at;
        const to = @min(end, at + span.text.len) - at;
        at += span.text.len;
        if (to <= from) continue;
        pen = try drawRun(r, pen, y, span.text[from..to], toneColor(span.tone));
    }
}

/// A diff's rows, drawn run by run in the colours the plan read them in: a line
/// of one kind is one colour, a context line is the code it is, and the words
/// that differ from a line's pair are marked.
fn drawDiff(plan: tool_card.DiffPlan, r: *Renderer, x: f32, y: f32, line_height: f32, metrics: Metrics) !void {
    const hang = @as(f32, @floatFromInt(tool_card.hang_cells)) * metrics.advance;
    var row: usize = 0;
    for (plan.steps) |step| {
        for (step.pieces, 0..) |piece, index| {
            try drawDiffPiece(step, piece, r, x + if (index == 0) 0 else hang, y + lineY(row + index, line_height), line_height);
        }
        row += step.pieces.len;
    }
}

/// One wrapped piece of a diff line: the piece is a byte range of the line, so
/// every run that overlaps it is drawn in its own colour, and a marked run is
/// underlined under the glyphs it covers - a mark the reader can see without
/// relying on the colour alone.
///
/// A line drawn cut has one piece that is an elided copy rather than a range of
/// the line, so it is drawn in the colour of the line's first run: a mark that
/// fell outside what is drawn is not drawn somewhere it does not belong.
fn drawDiffPiece(step: tool_card.DiffPlan.Step, piece: []const u8, r: *Renderer, x: f32, y: f32, line_height: f32) !void {
    if (step.cut) {
        const colour = if (step.runs.len > 0) step.runs[0].colour else theme.text;
        try r.text(x, y, piece, colour);
        return;
    }
    // The piece's stretch of the line, and the runs' stretches of the same
    // line: the arithmetic that meets them lives in the card vocabulary, where
    // it can be tested without a renderer - a run that begins past the piece is
    // "no overlap" rather than an underflow.
    var piece_range = tool_card.Stretch{ .from = @intFromPtr(piece.ptr) - @intFromPtr(step.text.ptr), .to = 0 };
    piece_range.to = piece_range.from + piece.len;
    var pen = x;
    var at: usize = 0;
    for (step.runs) |run| {
        // The runs are ordered and the walk moves forward, so once a run begins
        // past the piece none of the rest can meet it either.
        if (at >= piece_range.to) break;
        const run_range = tool_card.Stretch{ .from = at, .to = at + run.text.len };
        at = run_range.to;
        const part = tool_card.overlap(piece_range, run_range) orelse continue;
        const first = pen;
        pen = try drawRun(r, pen, y, run.text[part.from..part.to], run.colour);
        if (run.marked) try r.rect(.{ .x = first, .y = y + line_height - 3, .w = pen - first, .h = 2 }, run.colour);
    }
}

/// A section's bar: its name, what the section is about, and a rule filling
/// what is left of the row - so a section reads as a header over its payload
/// rather than as another row of it. This is the reference's labelled section
/// bar; it is a bar rather than a box because the panel is narrow.
fn drawBar(section: tool_card.Section, r: *Renderer, x: f32, y: f32, line_height: f32, columns: usize, metrics: Metrics, a: Allocator) !void {
    const label = try tool_card.flatten(a, section.label);
    const detail = try tool_card.flatten(a, section.detail);
    var buffer = try a.alloc(u8, label.len + 3);
    const name = wrap.elide(buffer, label, columns -| bar_rule_cells);
    var pen = try drawRun(r, x, y, name, theme.accent);
    if (detail.len != 0) {
        const room = columns -| (cellCount(name) + bar_gap_cells + bar_rule_cells);
        if (room > 0) {
            buffer = try a.alloc(u8, detail.len + 3);
            const value = wrap.elide(buffer, detail, room);
            pen = try drawRun(r, pen + bar_gap_cells * metrics.advance, y, value, theme.muted);
        }
    }
    // The rule runs from the pen to the panel's edge, which is what makes the
    // bar a bar rather than a line of text.
    const edge = x + @as(f32, @floatFromInt(columns)) * metrics.advance;
    const start = pen + bar_gap_cells * metrics.advance;
    if (edge > start + @as(f32, @floatFromInt(bar_rule_cells)) * metrics.advance) {
        try r.rect(.{ .x = start, .y = y + line_height / 2, .w = edge - start, .h = 1 }, theme.border);
    }
}

/// The gutter: one column of the card's left edge, in the colour its state is
/// read in. A settled call's gutter recedes, so the reader's eye goes to the
/// call that is still moving.
fn drawGutter(r: *Renderer, x: f32, y: f32, height: f32, colour: theme.Color) !void {
    try r.rect(.{ .x = x, .y = y, .w = gutter_width, .h = height }, colour);
}

/// One row of a card's own: the digest, or a marker naming what a budget left
/// out. A single span, so it needs no wrapping machinery of its own.
fn drawText(span: tool_card.Span, r: *Renderer, x: f32, y: f32) !void {
    try r.text(x, y, span.text, toneColor(span.tone));
}

/// Draw a run and answer where the pen stopped. `Renderer.text` draws a run but
/// does not say where it ended, and a chip's word and glyph, or a bar's label
/// and its detail, have to follow one another.
fn drawRun(r: *Renderer, x: f32, y: f32, bytes: []const u8, colour: theme.Color) !f32 {
    var pen = x;
    var at: usize = 0;
    while (at < bytes.len) : (at = text.next(bytes, at)) {
        pen += try r.glyphAt(pen, y + r.atlas.ascent, text.decode(bytes, at), colour);
    }
    return pen;
}

/// The columns a card's content has: the panel's, less the one a framed card's
/// gutter takes. A quiet card is not indented, because nothing is drawn down
/// its left edge.
fn contentColumns(card: tool_card.Card, width: f32, metrics: Metrics) usize {
    const gutter: usize = if (card.variant == .framed) gutter_cells else 0;
    return columnsFor(width, metrics) -| gutter;
}

/// The cells a width holds.
fn columnsFor(width: f32, metrics: Metrics) usize {
    return @intFromFloat(@max(1, width / @max(1, metrics.advance)));
}

/// `row` rows down from the top of the block.
fn lineY(row: usize, line_height: f32) f32 {
    return @as(f32, @floatFromInt(row)) * line_height;
}

fn cellCount(bytes: []const u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) : (at = text.next(bytes, at)) count += 1;
    return count;
}
