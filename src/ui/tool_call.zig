//! One tool call, as the transcript draws it.
//!
//! A call is not prose. What an agent did to a file is a label, a subject, and
//! the few facts that came with it, and a reader scanning a transcript is
//! looking for the call rather than reading it. So a call is drawn as an object
//! - a chip naming the tool and its state, with the one line that says what it
//! was about - and the detail underneath stays closed until the reader opens it.
//!
//! This module is the whole of a call's surface. `rows` says how many display
//! rows the block takes and `draw` fills them; both walk the same parts in the
//! same order - the chip, the fields, the diff - so a block can never be sized
//! for one arrangement and drawn in another.
//!
//! Nothing here owns the call: the record comes from the ACP client, and every
//! slice in it is borrowed for as long as the frame is.

const std = @import("std");
const acp = @import("../acp/tool_call.zig");
const diff = @import("diff.zig");
const theme = @import("theme.zig");
const wrap = @import("wrap.zig");
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

/// The pad inside the chip's pill, and the space after it before the subject:
/// enough that the pill reads as an object with the subject beside it, rather
/// than as a word with brackets around it.
const chip_pad: f32 = 7;
const chip_gap: f32 = 8;

/// How far the pill is inset from the row it sits in. A pill that filled the
/// row would be a bar.
const pill_inset: f32 = 3;

/// The cells a wrapped continuation of a field's value or of a diff line steps
/// in by, so a wrapped row reads as the row above it continued.
const hang_cells: usize = 2;

/// The fraction of the panel a field's label may take. Labels are words like
/// "path" and "command"; one that is not is cut rather than leaving its value no
/// column at all, and half the panel is the most a label may have of it.
const label_share: usize = 2;

/// How many display rows the call takes at this width: the chip's own row, and,
/// when it is open, its fields and its diff. A caller that lays out rows asks
/// this; the height in pixels is this times the line height. The allocator is
/// only used to read a diff the call carries, and a frame's arena is the right
/// one.
pub fn rows(a: Allocator, call: acp.ToolCall, width: f32, expanded: bool, metrics: Metrics) !usize {
    var count: usize = 1;
    if (!expanded) return count;
    const columns = columnsFor(width, metrics);
    const label = labelColumn(call.fields, columns);
    for (call.fields) |field| count += fieldRows(field, label, columns);
    if (call.diff) |bytes| {
        // A diff the reader will not get out of the parser is text, and is
        // counted as the text it is drawn as.
        const files = diff.parse(a, bytes) catch null;
        defer if (files) |parsed| diff.deinit(parsed, a);
        const lines = diffCount(files, bytes, columns);
        // One blank row between the fields and the diff, so the two are not
        // read as one list.
        if (lines > 0) count += 1 + lines;
    }
    return count;
}

/// Draw the block at `origin`. The caller owns the clip; the block starts on the
/// row grid `rows` counted and never leaves it.
pub fn draw(call: acp.ToolCall, r: *Renderer, origin: Vec2, width: f32, line_height: f32, expanded: bool, metrics: Metrics, a: Allocator) !void {
    const columns = columnsFor(width, metrics);
    try drawChip(call, r, origin, columns, line_height, metrics, a);
    if (!expanded) return;

    const label = labelColumn(call.fields, columns);
    var row: usize = 1;
    for (call.fields) |field| {
        try drawField(field, r, origin.x, origin.y + lineY(row, line_height), label, columns, line_height, metrics, a);
        row += fieldRows(field, label, columns);
    }

    const bytes = call.diff orelse return;
    const files = diff.parse(a, bytes) catch null;
    defer if (files) |parsed| diff.deinit(parsed, a);
    if (diffCount(files, bytes, columns) == 0) return;
    row += 1;
    _ = try drawDiff(files, bytes, r, origin.x, origin.y + lineY(row, line_height), line_height, columns, metrics, a);
}

/// The word a chip shows for a kind. A reader learns ten words once and then
/// scans them, which a bracket full of JSON never gave them.
pub fn kindLabel(kind: acp.Kind) []const u8 {
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

/// The mark a state shows, which is what carries the state when the colour
/// cannot: the same four marks the runs panel already uses, meaning the same
/// four things.
pub fn stateMark(state: acp.State) []const u8 {
    return switch (state) {
        .pending => "○",
        .in_progress => "●",
        .completed => "✓",
        .failed => "✗",
    };
}

/// The colour a state is read in: work that has not started is quiet, work in
/// flight is a warning, work that finished is the accent, and work that failed
/// is an error.
pub fn stateColor(state: acp.State) theme.Color {
    return switch (state) {
        .pending => theme.muted,
        .in_progress => theme.amber,
        .completed => theme.accent,
        .failed => theme.red,
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

/// The chip: the kind's word and the state's mark on a raised pill, then the
/// subject, cut to what is left of the row.
fn drawChip(call: acp.ToolCall, r: *Renderer, origin: Vec2, columns: usize, line_height: f32, metrics: Metrics, a: Allocator) !void {
    const word = kindLabel(call.kind);
    const mark = stateMark(call.state);
    const colour = stateColor(call.state);
    const cells = cellCount(word) + 1 + cellCount(mark);
    const pill: Rect = .{
        .x = origin.x,
        .y = origin.y + pill_inset,
        .w = @as(f32, @floatFromInt(cells)) * metrics.advance + chip_pad * 2,
        .h = @max(1, line_height - pill_inset * 2),
    };
    try r.rect(pill, theme.raised);
    _ = try drawRun(r, origin.x + chip_pad, origin.y, word, colour);
    // The mark starts at the word's column rather than where the word's last
    // glyph happened to end, so two chips of the same kind keep their marks in
    // one column.
    _ = try drawRun(r, origin.x + chip_pad + @as(f32, @floatFromInt(cellCount(word) + 1)) * metrics.advance, origin.y, mark, colour);

    // The subject is one line: a path or a command is scanned rather than read,
    // and a chip that wraps is a chip whose neighbours move.
    const room = columns -| (cells + 3);
    if (room == 0 or call.subject.len == 0) return;
    const buffer = try a.alloc(u8, call.subject.len + 3);
    try r.text(pill.x + pill.w + chip_gap, origin.y, wrap.elide(buffer, call.subject, room), theme.text);
}

/// One field: the label naming the datum, and the value itself, wrapped in the
/// column the label leaves. The label is drawn once, on the row the field
/// starts on, which is what `fieldRows` counts.
fn drawField(field: acp.Field, r: *Renderer, x: f32, y: f32, label: usize, columns: usize, line_height: f32, metrics: Metrics, a: Allocator) !void {
    const buffer = try a.alloc(u8, field.label.len + 3);
    try r.text(x, y, wrap.elide(buffer, field.label, label -| 2), theme.muted);
    var lines: std.ArrayList([]const u8) = .empty;
    try wrap.spans(a, field.value, columns -| label, &lines);
    for (lines.items, 0..) |line, index| {
        try r.text(x + @as(f32, @floatFromInt(label)) * metrics.advance, y + lineY(index, line_height), line, theme.text);
    }
}

/// A call's diff: the path it is about, then its hunks and their lines, exactly
/// as a fenced diff in the prose is read. `files` is null when the bytes are not
/// a diff, in which case they are drawn as the text they are rather than
/// dropped.
fn drawDiff(files: ?[]const diff.File, bytes: []const u8, r: *Renderer, x: f32, y: f32, line_height: f32, columns: usize, metrics: Metrics, a: Allocator) !usize {
    const parsed = files orelse return try drawText(bytes, r, x, y, line_height, columns, metrics, a);
    var row: usize = 0;
    for (parsed) |file| {
        // A fragment with no header has no name, and an empty name is not a row.
        if (file.path.len > 0) {
            const buffer = try a.alloc(u8, file.path.len + 3);
            try r.text(x, y + lineY(row, line_height), wrap.elide(buffer, file.path, columns), theme.muted);
            row += 1;
        }
        for (file.hunks) |hunk| {
            row += try drawWrapped(hunk.header, diffColor(.hunk), r, x, y + lineY(row, line_height), line_height, columns, metrics, a);
            for (hunk.lines) |line| {
                row += try drawWrapped(line.text, diffColor(line.kind), r, x, y + lineY(row, line_height), line_height, columns, metrics, a);
            }
        }
    }
    return row;
}

/// Bytes that did not read as a diff, drawn as the lines they were written in.
fn drawText(bytes: []const u8, r: *Renderer, x: f32, y: f32, line_height: f32, columns: usize, metrics: Metrics, a: Allocator) !usize {
    var row: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        row += try drawWrapped(line, theme.text, r, x, y + lineY(row, line_height), line_height, columns, metrics, a);
    }
    return row;
}

/// One line wrapped into the rows it needs, each continuation stepped in by the
/// same hang the count assumed. Answers how many rows it took.
fn drawWrapped(bytes: []const u8, colour: theme.Color, r: *Renderer, x: f32, y: f32, line_height: f32, columns: usize, metrics: Metrics, a: Allocator) !usize {
    var lines: std.ArrayList([]const u8) = .empty;
    try wrap.spans(a, bytes, columns -| hang_cells, &lines);
    for (lines.items, 0..) |line, index| {
        const indent = if (index == 0) 0 else @as(f32, @floatFromInt(hang_cells)) * metrics.advance;
        try r.text(x + indent, y + lineY(index, line_height), line, colour);
    }
    return lines.items.len;
}

/// Draw a run and answer where the pen stopped. `Renderer.text` draws a run but
/// does not say where it ended, and a chip's word and mark have to follow one
/// another.
fn drawRun(r: *Renderer, x: f32, y: f32, bytes: []const u8, colour: theme.Color) !f32 {
    var pen = x;
    var at: usize = 0;
    while (at < bytes.len) : (at = text.next(bytes, at)) {
        pen += try r.glyphAt(pen, y + r.atlas.ascent, text.decode(bytes, at), colour);
    }
    return pen;
}

/// The rows a field takes: the label's row holds the value's first row, and the
/// rest of the value wraps under it in the column the label leaves.
fn fieldRows(field: acp.Field, label: usize, columns: usize) usize {
    return wrap.rowCount(field.value, columns -| label);
}

/// The rows a diff takes: one per path, hunk header, and line, each wrapped at
/// the panel's column. A path that is not a diff is counted as the text it will
/// be drawn as.
fn diffCount(files: ?[]const diff.File, bytes: []const u8, columns: usize) usize {
    const parsed = files orelse return textRows(bytes, columns);
    const room = columns -| hang_cells;
    var count: usize = 0;
    for (parsed) |file| {
        if (file.path.len > 0) count += 1;
        for (file.hunks) |hunk| {
            count += wrap.rowCount(hunk.header, room);
            for (hunk.lines) |line| count += wrap.rowCount(line.text, room);
        }
    }
    return count;
}

/// The rows plain text takes, which is one wrap per line it was written in.
fn textRows(bytes: []const u8, columns: usize) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| count += wrap.rowCount(line, columns -| hang_cells);
    return count;
}

/// The column a field's value starts at: the widest label plus two cells, so a
/// reader scans the values down one column.
fn labelColumn(fields: []const acp.Field, columns: usize) usize {
    var widest: usize = 0;
    for (fields) |field| widest = @max(widest, cellCount(field.label));
    return @min(widest + 2, @max(3, columns / label_share));
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
