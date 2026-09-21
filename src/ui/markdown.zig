//! Markdown reading for the agent transcript.
//!
//! An agent writes Markdown, and a transcript that shows the asterisks of
//! `**bold**` is showing the source rather than the sentence. This reads one
//! message into the blocks an interface draws, and stops there: headings,
//! fenced code, bullets, quotes, rules, paragraphs, and the four inline runs.
//! It is not a Markdown implementation; it is the part of one that agent
//! transcripts are written in.
//!
//! Two things matter more than coverage. Nothing is dropped: a line this does
//! not recognise becomes a paragraph holding it verbatim, because a transcript
//! that silently eats a line is worse than one that shows it unstyled. And the
//! work is bounded: a document over `max_document_bytes`, or one that would
//! produce more than `max_blocks`, is refused by name - the same way
//! `services/theme_tm.zig` refuses a theme that is too large.
//!
//! Ownership is the caller's. Every slice in the result - each block's `text`
//! and `language`, each `Inline.text`, and the arrays holding them - is a
//! fresh allocation from the allocator passed to `parse`, and `deinit` gives
//! all of it back. Nothing points into `bytes`, so the transcript may be freed
//! while the blocks are still on screen. Empty slices are never allocated:
//! `""` and `&.{}` in a result are literals `deinit` skips over, not
//! allocations it frees.
//!
//! `text` is the line as written, markup and all. `inlines` is a reading of
//! that text, so the two agree about every character except the markup the
//! reading consumed: a `\*` in `text` is an escape, and the run it lands in
//! holds a bare `*`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The largest document this reads. A transcript nobody can read on one screen
/// is not a transcript, and the bound is what keeps a runaway agent message
/// from becoming an unbounded allocation.
pub const max_document_bytes = 1 << 20;

/// The most blocks one document may produce. The limit counts blocks rather
/// than lines because a block is what the interface draws and keeps.
pub const max_blocks = 4096;

pub const InlineKind = enum { plain, bold, italic, code };
pub const Inline = struct { kind: InlineKind, text: []const u8 };

pub const BlockKind = enum { paragraph, heading, bullet, code, quote, rule };
pub const Block = struct {
    kind: BlockKind,
    /// Heading level 1-6; 0 for everything else.
    level: u8 = 0,
    /// The block's own text. For `code` this is the code with the fence
    /// removed; for the others it is the line as written, markup and all.
    text: []const u8,
    /// A fenced block's language tag, empty when the fence was bare.
    language: []const u8 = "",
    /// Inline runs for the text blocks, in order. Empty for `code` and `rule`.
    inlines: []const Inline = &.{},
};

/// Read `bytes` into blocks, in document order.
///
/// Errors are `error.MarkdownTooLarge` and `error.TooManyBlocks`; nothing an
/// agent can write is a parse error, because whatever is not recognised is a
/// paragraph. An empty document is an empty slice rather than an error. Take
/// the result back with `deinit`.
pub fn parse(a: Allocator, bytes: []const u8) ![]Block {
    if (bytes.len > max_document_bytes) return error.MarkdownTooLarge;

    var blocks: std.ArrayList(Block) = .empty;
    errdefer {
        for (blocks.items) |block| releaseBlock(a, block);
        blocks.deinit(a);
    }
    // Consecutive lines that are neither blank nor the start of another block
    // are one paragraph, and the soft break an agent wrapped at becomes a
    // single space: the column the wrapper chose is not a break the reader
    // asked for, and the panel the transcript is drawn in is not that column.
    var paragraph: std.ArrayList(u8) = .empty;
    defer paragraph.deinit(a);

    var lines = Lines{ .bytes = bytes };
    while (lines.next()) |line| {
        if (isBlank(line)) {
            try flush(a, &blocks, &paragraph);
            continue;
        }
        if (fenceStart(line)) |fence| {
            try flush(a, &blocks, &paragraph);
            var block = Block{ .kind = .code, .text = try readFence(a, &lines, fence) };
            errdefer releaseBlock(a, block);
            block.language = try own(a, fence.language);
            try push(a, &blocks, block);
            continue;
        }
        if (headingLevel(line)) |level| {
            try flush(a, &blocks, &paragraph);
            try pushText(a, &blocks, .heading, level, line);
            continue;
        }
        if (isRule(line)) {
            try flush(a, &blocks, &paragraph);
            const block = Block{ .kind = .rule, .text = try own(a, line) };
            errdefer releaseBlock(a, block);
            try push(a, &blocks, block);
            continue;
        }
        if (isQuote(line)) {
            try flush(a, &blocks, &paragraph);
            try pushText(a, &blocks, .quote, 0, line);
            continue;
        }
        if (isBullet(line)) {
            try flush(a, &blocks, &paragraph);
            try pushText(a, &blocks, .bullet, 0, line);
            continue;
        }
        try appendParagraph(a, &paragraph, line);
    }
    try flush(a, &blocks, &paragraph);

    if (blocks.items.len == 0) {
        blocks.deinit(a);
        return &.{};
    }
    return blocks.toOwnedSlice(a);
}

/// Give back everything `parse` allocated for these blocks.
pub fn deinit(blocks: []Block, a: Allocator) void {
    for (blocks) |block| releaseBlock(a, block);
    if (blocks.len > 0) a.free(blocks);
}

fn releaseBlock(a: Allocator, block: Block) void {
    release(a, block.text);
    release(a, block.language);
    for (block.inlines) |run| release(a, run.text);
    if (block.inlines.len > 0) a.free(block.inlines);
}

/// Append a block, or refuse it. The bound is checked here so every path into
/// the list passes the same one. On failure the block stays the caller's, and
/// the caller's `errdefer` is what gives it back.
fn push(a: Allocator, blocks: *std.ArrayList(Block), block: Block) !void {
    if (blocks.items.len >= max_blocks) return error.TooManyBlocks;
    try blocks.append(a, block);
}

/// Append a single-line block: the line as written, plus the runs it reads as.
fn pushText(a: Allocator, blocks: *std.ArrayList(Block), kind: BlockKind, level: u8, line: []const u8) !void {
    var block = Block{ .kind = kind, .level = level, .text = try own(a, line) };
    errdefer releaseBlock(a, block);
    block.inlines = try parseInlines(a, line);
    try push(a, blocks, block);
}

/// Close the paragraph being collected, if it has any lines in it.
fn flush(a: Allocator, blocks: *std.ArrayList(Block), paragraph: *std.ArrayList(u8)) !void {
    if (paragraph.items.len == 0) return;
    var block = Block{ .kind = .paragraph, .text = try own(a, paragraph.items) };
    errdefer releaseBlock(a, block);
    block.inlines = try parseInlines(a, paragraph.items);
    try push(a, blocks, block);
    paragraph.clearRetainingCapacity();
}

/// Add one wrapped line to the paragraph under construction. Indentation a
/// wrapper inserted at the start of a continuation line is not text, and the
/// space between the lines is the soft break the reader should see.
fn appendParagraph(a: Allocator, paragraph: *std.ArrayList(u8), line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (paragraph.items.len > 0) try paragraph.append(a, ' ');
    try paragraph.appendSlice(a, trimmed);
}

/// The body of a fenced block: the lines between the fences, joined with the
/// newlines that were between them, and no newline where the closing fence
/// begins. An unterminated fence runs to the end of the transcript instead of
/// failing, because a message cut off mid-block is still a message.
fn readFence(a: Allocator, lines: *Lines, fence: Fence) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(a);
    var first = true;
    while (lines.next()) |line| {
        if (fenceClose(line, fence)) break;
        if (!first) try body.append(a, '\n');
        first = false;
        try body.appendSlice(a, line);
    }
    if (body.items.len == 0) return "";
    return body.toOwnedSlice(a);
}

/// One line of the transcript at a time. Lines borrow `bytes`, and the `\r` of
/// a CRLF transcript is separator rather than content.
const Lines = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(self: *Lines) ?[]const u8 {
        if (self.at >= self.bytes.len) return null;
        const end = std.mem.indexOfScalarPos(u8, self.bytes, self.at, '\n') orelse self.bytes.len;
        var line = self.bytes[self.at..end];
        self.at = if (end < self.bytes.len) end + 1 else self.bytes.len;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

/// An opening fence: three or more backticks or tildes, and whatever the agent
/// wrote after them. Its `language` points into the line it was read from.
const Fence = struct { marker: u8, width: usize, language: []const u8 };

fn fenceStart(line: []const u8) ?Fence {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 3) return null;
    const marker = trimmed[0];
    if (marker != '`' and marker != '~') return null;
    const width = runLength(trimmed, 0, marker);
    if (width < 3) return null;
    const info = std.mem.trim(u8, trimmed[width..], " \t");
    // The info string carries the language and sometimes attributes; the
    // language is its first word, which is what a highlighter is chosen by.
    const language = info[0 .. std.mem.indexOfAny(u8, info, " \t") orelse info.len];
    // A backtick fence cannot name a language with a backtick in it: that
    // would be the fence closing, so the line is not a fence at all.
    if (marker == '`' and std.mem.indexOfScalar(u8, language, '`') != null) return null;
    return .{ .marker = marker, .width = width, .language = language };
}

/// Whether `line` closes `fence`. A closer is the same marker, at least as
/// wide as the opener, and nothing else on the line, so a fence shown inside
/// the code is text.
fn fenceClose(line: []const u8, fence: Fence) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < fence.width) return false;
    for (trimmed) |c| {
        if (c != fence.marker) return false;
    }
    return true;
}

/// A heading's level, or null when the line is not a heading. Six hashes are
/// the deepest heading there is, so a seventh is text.
fn headingLevel(line: []const u8) ?u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    var level: usize = 0;
    while (level < trimmed.len and trimmed[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < trimmed.len and trimmed[level] != ' ' and trimmed[level] != '\t') return null;
    return @intCast(level);
}

/// A thematic break: three or more of one marker, and nothing else but the
/// spaces between them. A bullet is a marker and a space and then words, which
/// is why this is what decides between `---` and `- item`.
fn isRule(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    const marker = trimmed[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;
    var marks: usize = 0;
    for (trimmed) |c| {
        if (c == marker) {
            marks += 1;
        } else if (c != ' ' and c != '\t') return false;
    }
    return marks >= 3;
}

/// A quoted line, including the nested `>>` an agent writes to quote a quote.
fn isQuote(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return trimmed.len > 0 and trimmed[0] == '>';
}

/// An unordered item (`-`, `*`, `+`) or an ordered one (`1.`, `2)`). Both are
/// `bullet`: the interface marks them the same way, and the marker the agent
/// wrote is in the block's text either way.
fn isBullet(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 3) return false;
    switch (trimmed[0]) {
        '-', '*', '+' => return trimmed[1] == ' ' or trimmed[1] == '\t',
        else => {},
    }
    var digits: usize = 0;
    while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) digits += 1;
    if (digits == 0 or digits + 2 >= trimmed.len) return false;
    if (trimmed[digits] != '.' and trimmed[digits] != ')') return false;
    return trimmed[digits + 1] == ' ' or trimmed[digits + 1] == '\t';
}

/// Read the inline runs of one text block.
///
/// Runs are emitted in order and are never empty, so a renderer can walk them
/// and draw every character of the block. Delimiters with nothing between them
/// and delimiters with no partner stay where they are, as plain text: a lone
/// asterisk in a sentence is a character, not a broken pair.
fn parseInlines(a: Allocator, text: []const u8) ![]const Inline {
    if (text.len == 0) return &.{};
    var runs: std.ArrayList(Inline) = .empty;
    errdefer {
        for (runs.items) |run| release(a, run.text);
        runs.deinit(a);
    }
    // Text that is not (yet) part of a run. Delimiters that turn out to mean
    // nothing are appended here, which is how they survive.
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(a);

    var at: usize = 0;
    while (at < text.len) {
        switch (text[at]) {
            '\\' => at = try readEscape(a, text, at, &pending),
            '`' => at = try readCodeSpan(a, text, at, &runs, &pending),
            '*', '_' => at = try readEmphasis(a, text, at, &runs, &pending),
            else => {
                const next = std.mem.indexOfAnyPos(u8, text, at, "\\`*_") orelse text.len;
                try pending.appendSlice(a, text[at..next]);
                at = next;
            },
        }
    }
    try emit(a, &runs, &pending, .plain);
    if (runs.items.len == 0) return &.{};
    return runs.toOwnedSlice(a);
}

/// A backslash before punctuation is that punctuation, literal - the escape is
/// what keeps an asterisk from opening emphasis, and the backslash itself is
/// not part of the character it protects. Before anything else it is a
/// backslash: paths and regular expressions in a transcript are text.
fn readEscape(a: Allocator, text: []const u8, at: usize, pending: *std.ArrayList(u8)) !usize {
    if (at + 1 < text.len and isEscapable(text[at + 1])) {
        try pending.append(a, text[at + 1]);
        return at + 2;
    }
    try pending.append(a, '\\');
    return at + 1;
}

fn readCodeSpan(
    a: Allocator,
    text: []const u8,
    at: usize,
    runs: *std.ArrayList(Inline),
    pending: *std.ArrayList(u8),
) !usize {
    const ticks = runLength(text, at, '`');
    var scan = at + ticks;
    while (scan < text.len) {
        const close = std.mem.indexOfScalarPos(u8, text, scan, '`') orelse break;
        const width = runLength(text, close, '`');
        if (width == ticks) {
            // A code span is literal, escapes included: that is why an agent
            // writes one.
            try emit(a, runs, pending, .plain);
            try pending.appendSlice(a, text[at + ticks .. close]);
            try emit(a, runs, pending, .code);
            return close + ticks;
        }
        scan = close + width;
    }
    // No closing run of the same width, so the backticks are marks in the
    // sentence rather than a span.
    try pending.appendSlice(a, text[at .. at + ticks]);
    return at + ticks;
}

fn readEmphasis(
    a: Allocator,
    text: []const u8,
    at: usize,
    runs: *std.ArrayList(Inline),
    pending: *std.ArrayList(u8),
) !usize {
    const marker = text[at];
    const width = runLength(text, at, marker);
    const after = at + width;
    // Two or more is bold. A longer run is bold as well: `***word***` is what
    // an agent means by it, and the interface has no third weight to give.
    const kind: InlineKind = if (width >= 2) .bold else .italic;
    // An underscore inside a word is a word character; `src/foo_bar.zig` is a
    // path, however many pairs of underscores it happens to have.
    if (marker == '_' and at > 0 and std.ascii.isAlphanumeric(text[at - 1])) {
        try pending.appendSlice(a, text[at..after]);
        return after;
    }
    // A delimiter with nothing to open is a character: `5 * 3` is arithmetic.
    if (after >= text.len or std.ascii.isWhitespace(text[after])) {
        try pending.appendSlice(a, text[at..after]);
        return after;
    }
    if (findClose(text, after, marker, width)) |close| {
        try emit(a, runs, pending, .plain);
        try pending.appendSlice(a, text[after..close]);
        try emit(a, runs, pending, kind);
        return close + runLength(text, close, marker);
    }
    try pending.appendSlice(a, text[at..after]);
    return after;
}

/// The start of the run that closes an emphasis opened at `from`, or null when
/// there is none. A closer is at least as long as the opener, has text in
/// front of it that does not end in a space, and - for an underscore - is not
/// followed by a word character.
fn findClose(text: []const u8, from: usize, marker: u8, width: usize) ?usize {
    var scan = from;
    while (scan < text.len) {
        const close = std.mem.indexOfScalarPos(u8, text, scan, marker) orelse return null;
        const run = runLength(text, close, marker);
        const closed = close > from and
            !std.ascii.isWhitespace(text[close - 1]) and
            run >= width and
            (marker != '_' or close + run >= text.len or !std.ascii.isAlphanumeric(text[close + run]));
        if (closed) return close;
        scan = close + run;
    }
    return null;
}

/// Finish the run being collected. An empty run is not a run: it would be a
/// slice with nothing in it for a renderer to draw.
fn emit(a: Allocator, runs: *std.ArrayList(Inline), pending: *std.ArrayList(u8), kind: InlineKind) !void {
    if (pending.items.len == 0) return;
    const text = try a.dupe(u8, pending.items);
    errdefer a.free(text);
    try runs.append(a, .{ .kind = kind, .text = text });
    pending.clearRetainingCapacity();
}

fn runLength(text: []const u8, at: usize, marker: u8) usize {
    var end = at;
    while (end < text.len and text[end] == marker) end += 1;
    return end - at;
}

/// The ASCII punctuation a backslash can escape, which is the set CommonMark
/// names and the set that appears in a transcript.
fn isEscapable(c: u8) bool {
    return std.mem.indexOfScalar(u8, "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", c) != null;
}

/// Copy `bytes` into the caller's allocator. An empty slice is never
/// allocated, so `release` has nothing to skip over and no allocator has to
/// accept a zero-length free.
fn own(a: Allocator, bytes: []const u8) ![]const u8 {
    if (bytes.len == 0) return "";
    return a.dupe(u8, bytes);
}

fn release(a: Allocator, bytes: []const u8) void {
    if (bytes.len == 0) return;
    a.free(bytes);
}

test "a heading keeps its level and the line as written" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "# Title\n\n###### Deepest\n\n####### Too many\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(BlockKind.heading, blocks[0].kind);
    try std.testing.expectEqual(@as(u8, 1), blocks[0].level);
    try std.testing.expectEqualStrings("# Title", blocks[0].text);
    try std.testing.expectEqual(@as(u8, 6), blocks[1].level);
    try std.testing.expectEqualStrings("###### Deepest", blocks[1].text);
    // A seventh hash is not a heading, and it is not lost either.
    try std.testing.expectEqual(BlockKind.paragraph, blocks[2].kind);
    try std.testing.expectEqual(@as(u8, 0), blocks[2].level);
    try std.testing.expectEqualStrings("####### Too many", blocks[2].text);
}

test "a fenced block carries its language and keeps its newlines" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "```zig\nconst x = 1;\n\nreturn x;\n```\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.code, blocks[0].kind);
    try std.testing.expectEqualStrings("zig", blocks[0].language);
    try std.testing.expectEqualStrings("const x = 1;\n\nreturn x;", blocks[0].text);
    try std.testing.expectEqual(@as(usize, 0), blocks[0].inlines.len);
}

test "a fence with no language has an empty tag rather than an unknown one" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "~~~\nplain\n~~~\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(BlockKind.code, blocks[0].kind);
    try std.testing.expectEqualStrings("", blocks[0].language);
    try std.testing.expectEqualStrings("plain", blocks[0].text);
}

test "an unterminated fence runs to the end instead of failing" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "before\n\n```sh\nls -l\necho done\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[0].kind);
    try std.testing.expectEqual(BlockKind.code, blocks[1].kind);
    try std.testing.expectEqualStrings("sh", blocks[1].language);
    try std.testing.expectEqualStrings("ls -l\necho done", blocks[1].text);
}

test "the language is the first word of the fence's info string" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "```zig title=\"x\"\nconst a = 1;\n```\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(BlockKind.code, blocks[0].kind);
    try std.testing.expectEqualStrings("zig", blocks[0].language);
    try std.testing.expectEqualStrings("const a = 1;", blocks[0].text);
}

test "a fence inner line is code, not the end of the block" {
    const a = std.testing.allocator;
    // A narrower fence of the other marker, and a wider fence of its own: the
    // closer is the same marker at least as wide as the opener.
    const blocks = try parse(a, "~~~text\n```\ninner\n~~~\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.code, blocks[0].kind);
    try std.testing.expectEqualStrings("text", blocks[0].language);
    try std.testing.expectEqualStrings("```\ninner", blocks[0].text);

    const wider = try parse(a, "~~~\ninner\n~~~~\nafter\n");
    defer deinit(wider, a);
    try std.testing.expectEqualStrings("inner", wider[0].text);
    try std.testing.expectEqual(BlockKind.paragraph, wider[1].kind);
    try std.testing.expectEqualStrings("after", wider[1].text);
}

test "a CRLF transcript is the same transcript" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "one\r\ntwo\r\n\r\n```sh\r\nls\r\n```\r\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("one two", blocks[0].text);
    try std.testing.expectEqual(BlockKind.code, blocks[1].kind);
    try std.testing.expectEqualStrings("sh", blocks[1].language);
    try std.testing.expectEqualStrings("ls", blocks[1].text);
}

test "wrapped lines are one paragraph, not one each" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "The wrapper broke this\n  sentence across three\nlines.\n\nAfter the gap.\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[0].kind);
    try std.testing.expectEqualStrings("The wrapper broke this sentence across three lines.", blocks[0].text);
    try std.testing.expectEqualStrings("After the gap.", blocks[1].text);
}

test "bullets and ordered items are the same block" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "- first\n* second\n+ third\n1. one\n2) two\n");
    defer deinit(blocks, a);

    const expected = [_][]const u8{ "- first", "* second", "+ third", "1. one", "2) two" };
    try std.testing.expectEqual(expected.len, blocks.len);
    for (blocks, expected) |block, line| {
        try std.testing.expectEqual(BlockKind.bullet, block.kind);
        try std.testing.expectEqualStrings(line, block.text);
        try std.testing.expectEqual(@as(u8, 0), block.level);
    }
}

test "quotes keep their markers, nested ones included" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "> outer\n>> inner\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(BlockKind.quote, blocks[0].kind);
    try std.testing.expectEqualStrings("> outer", blocks[0].text);
    try std.testing.expectEqualStrings(">> inner", blocks[1].text);
}

test "rules break the paragraph around them" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "above\n---\n***\n___\nbelow\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 5), blocks.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[0].kind);
    for (blocks[1..4]) |block| {
        try std.testing.expectEqual(BlockKind.rule, block.kind);
        try std.testing.expectEqual(@as(usize, 0), block.inlines.len);
    }
    try std.testing.expectEqualStrings("below", blocks[4].text);
}

test "bold inside a paragraph becomes its own run" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "read **the manual** first\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(BlockKind.paragraph, blocks[0].kind);
    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try expectRun(runs[0], .plain, "read ");
    try expectRun(runs[1], .bold, "the manual");
    try expectRun(runs[2], .plain, " first");
}

test "italic and code runs sit beside plain text" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "use _this_ and `that_` now\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 5), runs.len);
    try expectRun(runs[0], .plain, "use ");
    try expectRun(runs[1], .italic, "this");
    try expectRun(runs[2], .plain, " and ");
    try expectRun(runs[3], .code, "that_");
    try expectRun(runs[4], .plain, " now");
}

test "an escaped delimiter is the character it protects" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "2 \\* 3 and a \\_literal\\_ pair\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try expectRun(runs[0], .plain, "2 * 3 and a _literal_ pair");
}

test "delimiters with no partner stay in the sentence" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "5 * 3 and a stray ` backtick\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try expectRun(runs[0], .plain, "5 * 3 and a stray ` backtick");
}

test "an underscore inside a word is a word character" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "edit src/foo_bar_baz.zig now\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try expectRun(runs[0], .plain, "edit src/foo_bar_baz.zig now");
}

test "text that is not a construct is still text" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "@@@ nothing here is markup: [[[a]]] => b\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[0].kind);
    try std.testing.expectEqualStrings("@@@ nothing here is markup: [[[a]]] => b", blocks[0].text);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].inlines.len);
    try expectRun(blocks[0].inlines[0], .plain, "@@@ nothing here is markup: [[[a]]] => b");
}

test "an empty document is no blocks rather than an error" {
    const a = std.testing.allocator;
    const empty = try parse(a, "");
    defer deinit(empty, a);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const blank = try parse(a, "\n\n   \n");
    defer deinit(blank, a);
    try std.testing.expectEqual(@as(usize, 0), blank.len);
}

test "a document past the bounds is refused by name" {
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, max_document_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.MarkdownTooLarge, parse(a, oversized));

    var document: std.ArrayList(u8) = .empty;
    defer document.deinit(a);
    for (0..max_blocks + 1) |_| try document.appendSlice(a, "- x\n");
    try std.testing.expectError(error.TooManyBlocks, parse(a, document.items));
}

fn expectRun(run: Inline, kind: InlineKind, text: []const u8) !void {
    try std.testing.expectEqual(kind, run.kind);
    try std.testing.expectEqualStrings(text, run.text);
}
