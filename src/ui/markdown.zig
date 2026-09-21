//! Markdown reading for the agent transcript.
//!
//! An agent writes Markdown, and a transcript that shows the asterisks of
//! `**bold**` is showing the source rather than the sentence. This reads one
//! message into the blocks an interface draws, and stops there: headings,
//! fenced code, bullets, quotes, rules, paragraphs, tables, math, and the
//! inline runs - plain, bold, italic, code, strikethrough, links, and math. It
//! is not a Markdown implementation; it is the part of one that agent
//! transcripts are written in.
//!
//! Math is read, not typeset. A span arrives as its body and the body is
//! verbatim, because turning `\frac{a}{b}` into something a terminal can draw
//! is the drawer's work, and a reader that had a guess at it here would be
//! guessing twice. What is this reader's work is deciding where a formula
//! starts and where it stops, which is the part that is not obvious: `$5 and
//! $10` is a sentence about money, and the anti-currency rules on the dollar
//! form are what keep it one.
//!
//! A table is one block rather than the lines it was written on: its cells are
//! already split and its column alignments already read, so a drawer places
//! the columns without reading the source again. What makes a table is the
//! delimiter row - `| --- | :-: |` - and that is the rule that keeps a
//! sentence with a `|` in it, of which an agent writes many, a sentence.
//!
//! Two things matter more than coverage. Nothing is dropped: a line this does
//! not recognise becomes a paragraph holding it verbatim, because a transcript
//! that silently eats a line is worse than one that shows it unstyled. And the
//! work is bounded: a document over `max_document_bytes`, or one that would
//! produce more than `max_blocks`, is refused by name - the same way
//! `services/theme_tm.zig` refuses a theme that is too large.
//!
//! Ownership is the caller's. Every slice in the result - each block's `text`
//! and `language`, each `Inline.text` and `Inline.destination`, each table
//! cell, row, and alignment, and the arrays holding them - is a fresh
//! allocation from the allocator passed to `parse`, and `deinit` gives all of
//! it back. Nothing points into `bytes`, so the transcript may be freed while
//! the blocks are still on screen. Empty slices are never allocated: `""` and
//! `&.{}` in a result are literals `deinit` skips over, not allocations it
//! frees.
//!
//! `text` is the line as written, markup and all. `inlines` is a reading of
//! that text, so the two agree about every character except the markup the
//! reading consumed: a `\*` in `text` is an escape, and the run it lands in
//! holds a bare `*`; an HTML entity is markup of the same kind, so the run
//! holding `&amp;` is the `&` the sentence reads as. A table is the exception
//! that proves the rule: its `text`
//! is the source lines joined with newlines, the fallback a drawer keeps for a
//! panel too narrow to draw columns in, and its `rows` are that same text with
//! the cells split at the pipes and only the `\|` escapes resolved.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The largest document this reads. A transcript nobody can read on one screen
/// is not a transcript, and the bound is what keeps a runaway agent message
/// from becoming an unbounded allocation.
pub const max_document_bytes = 1 << 20;

/// The most blocks one document may produce. The limit counts blocks rather
/// than lines because a block is what the interface draws and keeps.
pub const max_blocks = 4096;

/// The kinds of inline run a text block reads into. `strike`, `link`, and
/// `link_url` joined the original four: a struck run, the words of a link, and
/// the address a link shows when the words are not already that address.
/// `math` is the body of a formula with its delimiters taken off, kept
/// verbatim for a drawer that can read LaTeX.
pub const InlineKind = enum { plain, bold, italic, code, strike, link, link_url, math };

/// One inline run. `text` is what a reader reads. `destination` is where a link
/// points and is empty for every other kind: the address is kept on the run
/// even though only its text is drawn, because a drawer with a mouse can
/// hit-test a run, which is something the words alone cannot support.
pub const Inline = struct {
    kind: InlineKind,
    text: []const u8,
    destination: []const u8 = "",
};

/// A table column's alignment, read from its delimiter cell: `:---` left,
/// `:--:` centre, `---:` right. A bare `---` is `left` as well, because left
/// is what GFM draws for a column that names no side.
pub const Align = enum { left, center, right };

/// One table row: a slice of cells, in column order. The cell text is plain -
/// a table's cells carry no inline runs - and a cell is never null, an empty
/// cell being an empty string.
pub const Row = []const []const u8;

/// The kinds of block a transcript is read into. `table` joined the set
/// because an agent compares things in tables far more often than it lists
/// them, and a drawer handed the pipes as prose draws the pipes instead of the
/// columns. `math` is display math: a formula on lines of its own, which a
/// drawer can stack instead of fitting into the line it was written on.
pub const BlockKind = enum { paragraph, heading, bullet, code, quote, rule, table, math };
pub const Block = struct {
    kind: BlockKind,
    /// Heading level 1-6; 0 for everything else.
    level: u8 = 0,
    /// The block's own text. For `code` this is the code with the fence
    /// removed; for `math` it is the formula with its `$$` / `\[` delimiters
    /// removed, and with a bare `\begin{…}…\end{…}` environment left whole
    /// because its wrappers are the formula; for `table` it is the table's
    /// source lines joined with newlines, which is what a drawer falls back to
    /// when the panel is too narrow for columns; for the others it is the line
    /// as written, markup and all.
    text: []const u8,
    /// A fenced block's language tag, empty when the fence was bare.
    language: []const u8 = "",
    /// Inline runs for the text blocks, in order. Empty for `code`, `rule`,
    /// `table`, and `math`: a formula is not prose, so it has no runs to read
    /// and a drawer takes it as the one body it is.
    inlines: []const Inline = &.{},
    /// A table's rows. `rows[0]` is the header and holds one cell per column,
    /// `rows[1..]` are the body rows in document order. A body row is stored
    /// as the agent wrote it, so it may hold fewer or more cells than the
    /// header has columns: how wide the columns are is the drawer's question,
    /// and padding or clipping there costs the parser nothing. Empty for
    /// every other kind.
    rows: []const Row = &.{},
    /// A table's column alignments, one per column, in the order the columns
    /// are drawn. Empty for every other kind.
    aligns: []const Align = &.{},
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
        // Display math is looked for next, because like a fence it is opened
        // and closed by lines of its own: the body is not decided by the opener
        // line alone. Both forms of it - the `$$` / `\[` fence and the bare
        // `\begin{…}…\end{…}` environment - are the same block once found, and
        // neither consumes anything until it is found.
        if (displayOpener(line)) |closer| {
            if (try readDisplayMath(a, &lines, closer)) |body| {
                try pushMath(a, &blocks, &paragraph, body);
                continue;
            }
        }
        // Both delimiters on one line. An agent writing display math usually
        // writes `$$x$$` rather than opening and closing on lines of their own,
        // and reading only the opened form is what drew those as the source.
        if (singleLineMath(line)) |body| {
            try pushMath(a, &blocks, &paragraph, body);
            continue;
        }
        if (bareEnvironment(line)) |environment| {
            if (try readBareEnvironment(a, &lines, line, environment)) |body| {
                try pushMath(a, &blocks, &paragraph, body);
                continue;
            }
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
        // A table is the one block whose start cannot be decided from its own
        // line, so it is looked for last, after every line this recognises on
        // its own, and only then does the line become prose.
        if (try tableAt(a, &lines, line)) |table| {
            errdefer releaseBlock(a, table);
            try flush(a, &blocks, &paragraph);
            try push(a, &blocks, table);
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
    for (block.inlines) |run| {
        release(a, run.text);
        release(a, run.destination);
    }
    if (block.inlines.len > 0) a.free(block.inlines);
    for (block.rows) |row| freeRow(a, row);
    if (block.rows.len > 0) a.free(block.rows);
    if (block.aligns.len > 0) a.free(block.aligns);
}

/// Give back one table row: its cells, then the slice holding them.
fn freeRow(a: Allocator, row: Row) void {
    for (row) |cell| release(a, cell);
    if (row.len > 0) a.free(row);
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

/// The closer a display-math opener line asks for, or null when the line does
/// not open one. `$$` opens with `$$` and `\[` with `\]`: an opener and its
/// closer are the same width and the same shape, which is what keeps a `\[`
/// from being closed by a `$$` an agent wrote for something else.
fn displayOpener(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (std.mem.eql(u8, trimmed, "$$")) return "$$";
    if (std.mem.eql(u8, trimmed, "\\[")) return "\\]";
    return null;
}

/// A whole formula written between its delimiters on one line, or null.
///
/// The delimiters have to be the outermost characters, so prose that merely
/// contains them is left as prose; and they have to have something between them,
/// because two delimiters alone are the opener of a block whose body is still to
/// come rather than a formula with nothing in it.
fn singleLineMath(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    const forms = [_][2][]const u8{ .{ "$$", "$$" }, .{ "\\[", "\\]" } };
    for (forms) |form| {
        if (trimmed.len <= form[0].len + form[1].len) continue;
        if (!std.mem.startsWith(u8, trimmed, form[0])) continue;
        if (!std.mem.endsWith(u8, trimmed, form[1])) continue;
        return trimmed[form[0].len .. trimmed.len - form[1].len];
    }
    return null;
}

/// Whether a line is the closer `closer` alone, whitespace aside.
fn displayCloser(line: []const u8, closer: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, line, " \t"), closer);
}

/// The body of the display block whose opener line has just been read, or null
/// when the lines under it are not one - an opener that never closes is the two
/// characters it was written as, and the lines under it stay the paragraph they
/// were. Nothing is consumed unless the block is found, so the caller's walk is
/// where it was either way.
///
/// The body is read whole and kept verbatim: a matrix is `\\` row breaks and
/// `&` alignment, and blank lines inside a block of them are part of it rather
/// than the end of it.
fn readDisplayMath(a: Allocator, lines: *Lines, closer: []const u8) !?[]const u8 {
    const start = lines.at;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    var closed = false;
    while (lines.next()) |line| {
        if (displayCloser(line, closer)) {
            closed = true;
            break;
        }
        try appendSource(a, &body, line);
    }
    // `$$ $$` on one line and `$$` over `$$` are the same nothing, and a block
    // with nothing in it is not a block: both stay the text they were.
    if (!closed or std.mem.trim(u8, body.items, " \t\n").len == 0) {
        lines.at = start;
        return null;
    }
    return try body.toOwnedSlice(a);
}

/// The math environment a line opens with `\begin{…}`, or null when the line
/// does not open one. An agent writes a display environment without the `$$`
/// fence around it far more often than with, and the wrappers are part of the
/// formula, so this is the block form for that spelling.
fn bareEnvironment(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const opening = "\\begin{";
    if (!std.mem.startsWith(u8, trimmed, opening)) return null;
    const rest = trimmed[opening.len..];
    const end = std.mem.indexOfScalar(u8, rest, '}') orelse return null;
    const environment = rest[0..end];
    if (!isEnvironmentName(environment) or !isBareMathEnvironment(environment)) return null;
    return environment;
}

/// Whether a line holds the `\end{environment}` that closes `environment`, with
/// nothing after it on the line but whitespace. The math an environment writes
/// on the line its `\end` sits on belongs to the block; anything after the
/// `\end` does not, which is what makes this the line that closes it.
fn environmentClose(line: []const u8, environment: []const u8) bool {
    const closing = "\\end{";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, closing)) |at| {
        const rest = line[at + closing.len ..];
        const named = rest.len > environment.len and
            std.mem.startsWith(u8, rest, environment) and
            rest[environment.len] == '}';
        if (named and isBlank(rest[environment.len + 1 ..])) return true;
        from = at + closing.len;
    }
    return false;
}

/// Whether `environment` is written the way a LaTeX environment name is: at
/// least one letter, and at most one trailing `*` for the starred form.
fn isEnvironmentName(environment: []const u8) bool {
    if (environment.len == 0) return false;
    for (environment, 0..) |c, at| {
        if (c == '*' and at == environment.len - 1) break;
        if (!std.ascii.isAlphabetic(c)) return false;
    }
    return true;
}

/// The display-math environments that are a formula without any delimiters
/// around them. Text-mode environments are deliberately not here: a
/// `\begin{itemize}` an agent quotes in prose is prose, and turning it into
/// math would be worse than leaving it as written.
const bare_math_environments = [_][]const u8{
    "matrix",    "smallmatrix", "pmatrix",  "bmatrix",  "Bmatrix",  "vmatrix",
    "Vmatrix",   "cases",       "dcases",   "rcases",   "drcases",  "aligned",
    "alignedat", "align",       "alignat",  "split",    "gathered", "gatheredat",
    "gather",    "multline",    "equation", "eqnarray", "array",    "subarray",
};

/// Whether `environment` is one of those. A starred variant is the same
/// environment: `align*` is `align` and reads the same way.
fn isBareMathEnvironment(environment: []const u8) bool {
    const name = if (environment.len > 0 and environment[environment.len - 1] == '*')
        environment[0 .. environment.len - 1]
    else
        environment;
    for (bare_math_environments) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

/// The body of the bare environment whose opener line is `opener`, or null when
/// the lines under it are not one. The environment closes with its own
/// `\end{…}`, and it cannot span a blank line: a blank line ends the paragraph
/// the environment was written as, and a `\begin` that never closes inside that
/// paragraph is the text it looks like.
fn readBareEnvironment(a: Allocator, lines: *Lines, opener: []const u8, environment: []const u8) !?[]const u8 {
    const start = lines.at;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    var line = opener;
    while (true) {
        try appendSource(a, &body, line);
        if (environmentClose(line, environment)) return try body.toOwnedSlice(a);
        line = lines.next() orelse break;
        if (isBlank(line)) break;
    }
    lines.at = start;
    return null;
}

/// Append a display-math block, closing the paragraph above it first. The body
/// is the block's from here on, so a failure anywhere gives it back exactly
/// once.
fn pushMath(a: Allocator, blocks: *std.ArrayList(Block), paragraph: *std.ArrayList(u8), body: []const u8) !void {
    const block = Block{ .kind = .math, .text = body };
    errdefer releaseBlock(a, block);
    try flush(a, blocks, paragraph);
    try push(a, blocks, block);
}

/// Read the table whose header line is `line`, or null when the lines there
/// are not a table after all. Nothing is consumed unless the answer is yes, so
/// a header that turns out to be prose is still the paragraph line it was.
///
/// The delimiter row - the line under the header - is what decides, and it is
/// the only thing that decides: a header whose row is missing, malformed, or
/// shaped for a different number of columns leaves both lines prose, which is
/// what keeps a sentence an agent wrote a `|` into a sentence. Both rows also
/// have to carry a pipe of their own, without which the `---` under a line of
/// prose would read as the delimiter row of a one-column table and the rule it
/// is would be gone.
fn tableAt(a: Allocator, lines: *Lines, line: []const u8) !?Block {
    const delimiter = lines.peek() orelse return null;
    if (!hasCellBreak(line) or !hasCellBreak(delimiter)) return null;
    const aligns = (try readAligns(a, delimiter, countCells(line))) orelse return null;
    errdefer a.free(aligns);

    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |row| freeRow(a, row);
        rows.deinit(a);
    }
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);

    try appendRow(a, &rows, line);
    try appendSource(a, &source, line);
    // The peek read the delimiter row; take it for real now that the two lines
    // have proved to be a table.
    _ = lines.next();
    try appendSource(a, &source, delimiter);
    // The body runs to the first blank line, and to the first line with no
    // pipe of its own: a row is a row because it has columns to put in, and a
    // line without one belongs to whatever block comes next. That line is
    // looked at rather than read, so it is still there for the parser.
    while (lines.peek()) |body| {
        if (isBlank(body) or !hasCellBreak(body)) break;
        _ = lines.next();
        try appendRow(a, &rows, body);
        try appendSource(a, &source, body);
    }

    const owned = try rows.toOwnedSlice(a);
    errdefer {
        for (owned) |row| freeRow(a, row);
        a.free(owned);
    }
    return Block{
        .kind = .table,
        .text = try own(a, source.items),
        .rows = owned,
        .aligns = aligns,
    };
}

/// Split one table row into cells, each copied into the caller's allocator
/// with its `\|` escapes resolved. The row is kept exactly as wide as the
/// agent wrote it, short rows and long rows alike: how wide a column is drawn
/// is the drawer's question, and a parser that padded here would be answering
/// it for a panel it cannot see.
fn splitRow(a: Allocator, line: []const u8) !Row {
    var cells: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (cells.items) |cell| release(a, cell);
        cells.deinit(a);
    }
    var scan = Cells.init(line);
    while (scan.next()) |raw| {
        const cell = try ownCell(a, raw);
        errdefer release(a, cell);
        try cells.append(a, cell);
    }
    return cells.toOwnedSlice(a);
}

/// The alignment of each column, read from a table's delimiter row, or null
/// when `line` is not a delimiter row for a header of `columns` columns.
///
/// A delimiter cell is one or more hyphens with a colon at either end and
/// nothing else - `:---` left, `:--:` centre, `---:` right, `---` left as GFM
/// draws it - and there is one cell per column. A row that disagrees with the
/// header about the count is not a delimiter row, and so the header is not a
/// table.
fn readAligns(a: Allocator, line: []const u8, columns: usize) !?[]Align {
    var aligns: std.ArrayList(Align) = .empty;
    defer aligns.deinit(a);
    var cells = Cells.init(line);
    while (cells.next()) |raw| {
        const column = delimiterAlign(raw) orelse return null;
        try aligns.append(a, column);
    }
    if (aligns.items.len != columns) return null;
    return try aligns.toOwnedSlice(a);
}

/// One delimiter row cell's alignment, or null when the cell is not a
/// delimiter cell at all.
fn delimiterAlign(cell: []const u8) ?Align {
    var text = std.mem.trim(u8, cell, " \t");
    const left = text.len > 0 and text[0] == ':';
    if (left) text = text[1..];
    const right = text.len > 0 and text[text.len - 1] == ':';
    if (right) text = text[0 .. text.len - 1];
    if (text.len == 0) return null;
    for (text) |c| {
        if (c != '-') return null;
    }
    if (left and right) return .center;
    if (right) return .right;
    return .left;
}

/// Split one row and append it. On failure the row stays the caller's, and the
/// list's own `errdefer` is what gives back the rows already in it.
fn appendRow(a: Allocator, rows: *std.ArrayList(Row), line: []const u8) !void {
    const row = try splitRow(a, line);
    errdefer freeRow(a, row);
    try rows.append(a, row);
}

/// Add one source line to a block's text, with the newline that was between it
/// and the line before. The lines are kept as written - a table's source and a
/// formula's body are both read back verbatim when a panel has no room for
/// anything better - so nothing is trimmed here.
fn appendSource(a: Allocator, source: *std.ArrayList(u8), line: []const u8) !void {
    if (source.items.len > 0) try source.append(a, '\n');
    try source.appendSlice(a, line);
}

/// Whether a row has a pipe that separates cells. A row of a table has one, a
/// `\|` is not one, and a line without one is what ends a table.
fn hasCellBreak(line: []const u8) bool {
    for (line, 0..) |c, at| {
        if (c == '|' and !isEscaped(line, at)) return true;
    }
    return false;
}

/// How many cells a row holds. The count is what a delimiter row has to agree
/// with, and it is taken without splitting anything because the agreement is
/// what decides whether there is anything worth splitting.
fn countCells(line: []const u8) usize {
    var cells = Cells.init(line);
    var count: usize = 0;
    while (cells.next() != null) count += 1;
    return count;
}

/// The cells of one table row, read in order. A pipe separates two cells, the
/// pipe at either end of the row is its edge rather than an empty cell, and
/// `\|` is a pipe rather than a separation: an agent writes regular
/// expressions in tables, and a regex with an alternation in it is not a row
/// of extra columns.
const Cells = struct {
    text: []const u8,
    at: usize = 0,

    fn init(line: []const u8) Cells {
        var text = std.mem.trim(u8, line, " \t");
        if (text.len > 0 and text[0] == '|') text = text[1..];
        // Only an unescaped pipe ends the row, so `| a \|` is a row of one
        // cell whose text ends in the pipe it protects.
        if (text.len > 0 and text[text.len - 1] == '|' and !isEscaped(text, text.len - 1)) {
            text = text[0 .. text.len - 1];
        }
        return .{ .text = text };
    }

    /// The next cell, trimmed and still escaped, or null at the end. A row
    /// always holds at least one cell: an empty row is one empty cell rather
    /// than none, which is what a row of nothing but edge pipes is.
    fn next(self: *Cells) ?[]const u8 {
        if (self.at > self.text.len) return null;
        var end = self.at;
        while (end < self.text.len) : (end += 1) {
            if (self.text[end] == '|' and !isEscaped(self.text, end)) break;
        }
        const raw = std.mem.trim(u8, self.text[self.at..end], " \t");
        self.at = if (end < self.text.len) end + 1 else self.text.len + 1;
        return raw;
    }
};

/// Copy one cell into the caller's allocator with the `\|` a cell may hold
/// resolved to the pipe it protects. Nothing else is an escape: a cell is not
/// inline Markdown, so `\d` in a cell is the two characters it looks like.
fn ownCell(a: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return own(a, raw);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var at: usize = 0;
    while (at < raw.len) {
        if (raw[at] == '\\' and at + 1 < raw.len and raw[at + 1] == '|') {
            try text.append(a, '|');
            at += 2;
        } else {
            try text.append(a, raw[at]);
            at += 1;
        }
    }
    return own(a, text.items);
}

/// Whether the character at `at` is preceded by an odd run of backslashes, and
/// so is escaped rather than a mark of its own.
fn isEscaped(text: []const u8, at: usize) bool {
    var backslashes: usize = 0;
    var scan = at;
    while (scan > 0 and text[scan - 1] == '\\') {
        backslashes += 1;
        scan -= 1;
    }
    return backslashes % 2 == 1;
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

    /// The next line without reading it. A table begins with a header and a
    /// delimiter row, so the line in hand cannot be judged a header until the
    /// line under it has been looked at.
    fn peek(self: *Lines) ?[]const u8 {
        const at = self.at;
        const line = self.next();
        self.at = at;
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
        for (runs.items) |run| {
            release(a, run.text);
            release(a, run.destination);
        }
        runs.deinit(a);
    }
    // Text that is not (yet) part of a run. Delimiters that turn out to mean
    // nothing are appended here, which is how they survive.
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(a);

    var at: usize = 0;
    while (at < text.len) {
        switch (text[at]) {
            '\\', '$' => at = try readDelimiter(a, text, at, &runs, &pending),
            '`' => at = try readCodeSpan(a, text, at, &runs, &pending),
            '*', '_' => at = try readEmphasis(a, text, at, &runs, &pending),
            '~' => at = try readStrike(a, text, at, &runs, &pending),
            '[' => at = try readLink(a, text, at, &runs, &pending),
            '<' => at = try readAutolink(a, text, at, &runs, &pending),
            '&' => at = try readEntity(a, text, at, &pending),
            else => {
                const next = std.mem.indexOfAnyPos(u8, text, at, "\\`*_~[<&$") orelse text.len;
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

/// A delimiter in prose: `$` and the `\(` / `\[` behind a backslash open a
/// formula, the rest of the backslash cases are the escapes they look like, and
/// a dollar that closes nothing is the character it was written as.
///
/// The math reading comes first because `\(x\)` is a formula rather than an
/// escaped parenthesis. An opener with no partner - `\(`, a lone `$`, the first
/// half of `$5 and $10` - is put back in the sentence as the characters it was
/// written with, which is the whole of the fallback: nothing is dropped, and
/// nothing is swallowed to the end of the line.
fn readDelimiter(
    a: Allocator,
    text: []const u8,
    at: usize,
    runs: *std.ArrayList(Inline),
    pending: *std.ArrayList(u8),
) !usize {
    if (try readMath(a, text, at, runs, pending)) |end| return end;
    if (text[at] == '$') {
        try pending.append(a, '$');
        return at + 1;
    }
    return readEscape(a, text, at, pending);
}

/// A math span read from `text` at `at`, or null when the delimiter there does
/// not open one. The delimiters are consumed and the body is kept verbatim,
/// because what the LaTeX in it means is the drawer's reading and not this
/// one's: a run of kind `math` is the formula with its markup intact.
fn readMath(
    a: Allocator,
    text: []const u8,
    at: usize,
    runs: *std.ArrayList(Inline),
    pending: *std.ArrayList(u8),
) !?usize {
    const span = mathSpan(text, at) orelse return null;
    try emit(a, runs, pending, .plain);
    try pending.appendSlice(a, span.body);
    try emit(a, runs, pending, .math);
    return span.end;
}

/// A math span: the body between the delimiters, and where the span ends. The
/// body is a slice of the source rather than a copy, and it is never empty.
const MathSpan = struct {
    body: []const u8,
    end: usize,
};

/// The math span written at `at`, or null when what is written there is not one.
///
/// The four openers are `$`, `$$`, `\(` and `\[`, and each closer is as wide
/// and as shaped as its opener. Whether a `$` is an opener at all is decided by
/// the anti-currency rules on `dollarCloser`, which is the part of this that
/// keeps a message's prices from becoming formulas.
fn mathSpan(text: []const u8, at: usize) ?MathSpan {
    if (at >= text.len) return null;
    if (text[at] == '$') {
        const wide = at + 1 < text.len and text[at + 1] == '$';
        const width: usize = if (wide) 2 else 1;
        const body_start = at + width;
        if (body_start >= text.len) return null;
        const close = if (wide) closerIndex(text, "$$", body_start) else dollarCloser(text, at);
        const end = close orelse return null;
        const body = text[body_start..end];
        // `$$ $$` is no formula, but `\(\)` and `\[\]` are unambiguous enough
        // to keep - there is no currency written that way.
        if (wide and std.mem.trim(u8, body, " \t\n").len == 0) return null;
        return .{ .body = body, .end = end + width };
    }
    if (text[at] != '\\' or at + 1 >= text.len) return null;
    const closer: []const u8 = switch (text[at + 1]) {
        '(' => "\\)",
        '[' => "\\]",
        else => return null,
    };
    const body_start = at + 2;
    const close = closerIndex(text, closer, body_start) orelse return null;
    // An empty body is a span with nothing to draw and nothing to say, so the
    // brackets stay the characters they were written as.
    if (close == body_start) return null;
    return .{ .body = text[body_start..close], .end = close + closer.len };
}

/// The `$` that closes the span opened at `open`, or null when there is none.
///
/// These are Pandoc's anti-currency heuristics, and the whole reason this is not
/// an `indexOf`: the opener must not be followed by whitespace, the closer must
/// not be preceded by whitespace nor followed by a digit, and `\$` is a literal
/// dollar rather than a closer. A candidate that fails the whitespace rule ends
/// the search rather than being skipped - that is the rule that leaves `$5 and
/// $10` a sentence and finds no second opener in it - while a candidate followed
/// by a digit is currency and the search goes on past it.
fn dollarCloser(text: []const u8, open: usize) ?usize {
    const after = text[open + 1];
    if (after == ' ' or after == '\t' or after == '\n' or after == '$') return null;
    var at = open + 1;
    while (at < text.len) : (at += 1) {
        const c = text[at];
        if (c == '\\') {
            // Whatever the backslash protects is body text: `$a \$ b$` closes
            // at the final dollar, not at the escaped one.
            at += 1;
            continue;
        }
        if (c == '\n') return null;
        if (c != '$') continue;
        const before = text[at - 1];
        if (before == ' ' or before == '\t') return null;
        if (at + 1 < text.len and std.ascii.isDigit(text[at + 1])) continue;
        const body = std.mem.trim(u8, text[open + 1 .. at], " \t\n");
        return if (body.len > 0) at else null;
    }
    return null;
}

/// The closer `\)`, `\]`, or `$$` at or after `from`, or null when there is
/// none. A closer an odd run of backslashes sits in front of is escaped, and so
/// is body text: in `\(a \\) b\)` the `\\` is a TeX row break and the span
/// closes at the final `\)`.
fn closerIndex(text: []const u8, closer: []const u8, from: usize) ?usize {
    var scan = from;
    while (std.mem.indexOfPos(u8, text, scan, closer)) |at| {
        if (!isEscaped(text, at)) return at;
        scan = at + 1;
    }
    return null;
}

/// An HTML entity read from `text` at `at`: the character it names, and how
/// many bytes of source it takes up. The set is the reference's set - the six
/// named entities an agent writes, and the decimal and hexadecimal numeric
/// forms - and it is the same set wherever prose is read, code spans aside:
/// text is text whether or not something else is styling it.
fn readEntity(a: Allocator, text: []const u8, at: usize, pending: *std.ArrayList(u8)) !usize {
    const entity = decodeEntity(text, at) orelse {
        try pending.append(a, '&');
        return at + 1;
    };
    var encoded: [4]u8 = undefined;
    // A code point that `decodeEntity` accepted always encodes, but the length
    // is the encoder's answer rather than something counted here.
    const length = std.unicode.utf8Encode(entity.codepoint, &encoded) catch {
        try pending.append(a, '&');
        return at + 1;
    };
    try pending.appendSlice(a, encoded[0..length]);
    return at + entity.width;
}

/// Append bytes that are already known to be prose - the words of an emphasis,
/// a struck run, or a link - resolving the entities in them on the way. The
/// delimiters around those words were read by the time this is called, so an
/// entity inside them is a character and not markup.
fn appendText(a: Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const next = std.mem.indexOfScalarPos(u8, bytes, at, '&') orelse bytes.len;
        try out.appendSlice(a, bytes[at..next]);
        if (next == bytes.len) break;
        at = try readEntity(a, bytes, next, out);
    }
}

/// An entity's decoded character, and the width of the source form it was read
/// from. `width` counts the ampersand and the semicolon, so the reader knows
/// where the sentence continues.
const Entity = struct { width: usize, codepoint: u21 };

/// The entity starting at `at`, or null when the ampersand there begins one.
/// `&amp;` is an entity, `&amp` is an ampersand and three letters, and so is
/// `&foo;` - a name this does not know stays as written.
fn decodeEntity(text: []const u8, at: usize) ?Entity {
    const after = at + 1;
    const end = std.mem.indexOfScalarPos(u8, text, after, ';') orelse return null;
    const body = text[after..end];
    if (body.len == 0) return null;
    const codepoint = if (body[0] == '#')
        numericEntity(body[1..])
    else
        namedEntity(body);
    return .{ .width = end + 1 - at, .codepoint = codepoint orelse return null };
}

/// The character a named entity names, or null for a name that is not one of
/// the six. Names are read as the reference reads them, without regard to case.
fn namedEntity(body: []const u8) ?u21 {
    const names = [_]struct { name: []const u8, codepoint: u21 }{
        .{ .name = "nbsp", .codepoint = 0xa0 },
        .{ .name = "lt", .codepoint = '<' },
        .{ .name = "gt", .codepoint = '>' },
        .{ .name = "quot", .codepoint = '"' },
        .{ .name = "apos", .codepoint = '\'' },
        .{ .name = "amp", .codepoint = '&' },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(body, entry.name)) return entry.codepoint;
    }
    return null;
}

/// The character a numeric entity names: `&#NN;` is decimal and `&#xHH;` is
/// hexadecimal. A number that does not name a character - past the last plane,
/// half of a surrogate pair, or zero, which is a byte no transcript draws -
/// names nothing, and the entity stays as written rather than becoming a
/// character that is not there.
fn numericEntity(body: []const u8) ?u21 {
    var digits = body;
    var base: u32 = 10;
    if (body.len > 0 and (body[0] == 'x' or body[0] == 'X')) {
        digits = body[1..];
        base = 16;
    }
    if (digits.len == 0) return null;
    var value: u32 = 0;
    for (digits) |c| {
        const digit: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => if (base == 16) c - 'a' + 10 else return null,
            'A'...'F' => if (base == 16) c - 'A' + 10 else return null,
            else => return null,
        };
        // Checked as the digits are read, so a long number stops here instead
        // of wrapping around into a small one.
        value = value * base + digit;
        if (value > 0x10ffff) return null;
    }
    if (value == 0 or (value >= 0xd800 and value <= 0xdfff)) return null;
    return @intCast(value);
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
        try appendText(a, pending, text[after..close]);
        try emit(a, runs, pending, kind);
        return close + runLength(text, close, marker);
    }
    try pending.appendSlice(a, text[at..after]);
    return after;
}

/// A struck run: `~~gone~~`. Two tildes open it and two close it, so a single
/// tilde is a character - `~/.cache` is a path an agent writes, and a lone mark
/// is not a retraction. A pair with no partner stays where it was written
/// rather than swallowing the rest of the line.
fn readStrike(
    a: Allocator,
    text: []const u8,
    at: usize,
    runs: *std.ArrayList(Inline),
    pending: *std.ArrayList(u8),
) !usize {
    const width = runLength(text, at, '~');
    const after = at + width;
    // One tilde is not a pair, and tildes with nothing to open are marks in
    // the sentence rather than a pair either.
    if (width < 2 or after >= text.len or std.ascii.isWhitespace(text[after])) {
        try pending.appendSlice(a, text[at..after]);
        return after;
    }
    if (findClose(text, after, '~', width)) |close| {
        try emit(a, runs, pending, .plain);
        try appendText(a, pending, text[after..close]);
        try emit(a, runs, pending, .strike);
        return close + runLength(text, close, '~');
    }
    try pending.appendSlice(a, text[at..after]);
    return after;
}

/// A link: `[words](address)`. Both halves survive - the words a reader reads
/// and the address they point at - and the address is shown beside the words
/// when it is not already them, because a transcript with no click in it still
/// has to say where a link goes. Anything malformed is left as the text it was
/// written as, so an unmatched `[` costs nothing.
fn readLink(
    a: Allocator,
    text: []const u8,
    at: usize,
    runs: *std.ArrayList(Inline),
    pending: *std.ArrayList(u8),
) !usize {
    const after = at + 1;
    const label_end = labelEnd(text, after) orelse {
        try pending.append(a, '[');
        return after;
    };
    const destination_end = destinationEnd(text, label_end + 2) orelse {
        try pending.append(a, '[');
        return after;
    };
    const link_text = text[after..label_end];
    const destination = linkDestination(text[label_end + 2 .. destination_end]);
    // A link needs both halves: words to read and an address to go to. Half of
    // one is the punctuation it was written with.
    if (link_text.len == 0 or destination.len == 0) {
        try pending.append(a, '[');
        return after;
    }
    try emit(a, runs, pending, .plain);
    // The words of a link read as any other prose, entities and all. The
    // address does not: it is followed rather than read, so it stays exactly
    // as the agent wrote it.
    try appendText(a, pending, link_text);
    try emitLink(a, runs, pending, destination);
    // Only when the words are not already the address: a bare URL is not worth
    // printing twice.
    if (!std.mem.eql(u8, link_text, destination)) {
        try pending.append(a, '(');
        try pending.appendSlice(a, destination);
        try pending.append(a, ')');
        try emit(a, runs, pending, .link_url);
    }
    return destination_end + 1;
}

/// The `]` that opens a link's address, or null when the `[` at `from - 1`
/// does not begin one. The `]` has to be followed by the `(` of an address and
/// has to be unescaped; brackets between the two are part of the words, which
/// is what lets a link be written about `[index]` entries.
fn labelEnd(text: []const u8, from: usize) ?usize {
    var scan = from;
    while (scan < text.len) {
        const close = std.mem.indexOfScalarPos(u8, text, scan, ']') orelse return null;
        if (!isEscaped(text, close) and close + 1 < text.len and text[close + 1] == '(') return close;
        scan = close + 1;
    }
    return null;
}

/// The `)` that ends the address whose body starts at `from` - the byte after
/// the `(` - or null when the address is never closed. Parentheses inside the
/// address are counted, because a URL is allowed to hold them - a wiki title
/// with `(disambiguation)` in it is one address, not an address with a stray
/// `)` after it.
fn destinationEnd(text: []const u8, from: usize) ?usize {
    var depth: usize = 1;
    var scan = from;
    while (scan < text.len) {
        switch (text[scan]) {
            '(' => if (!isEscaped(text, scan)) {
                depth += 1;
            },
            ')' => if (!isEscaped(text, scan)) {
                depth -= 1;
                if (depth == 0) return scan;
            },
            else => {},
        }
        scan += 1;
    }
    return null;
}

/// An address as written between a link's parentheses, with the space around
/// it and the title an agent may put after it taken off: the address is what a
/// reader follows, and `<...>` around it is CommonMark's way of writing an
/// address that could otherwise be read as markup.
fn linkDestination(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const address = trimmed[0 .. std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len];
    if (address.len >= 2 and address[0] == '<' and address[address.len - 1] == '>') {
        return address[1 .. address.len - 1];
    }
    return address;
}

/// A link written as its own address: `<https://example.com>`. The address is
/// both the words and the destination, so the two are equal and nothing is
/// shown twice. What is not an address - `<div>`, `a < b` - keeps its angle
/// bracket and stays the sentence it was.
fn readAutolink(
    a: Allocator,
    text: []const u8,
    at: usize,
    runs: *std.ArrayList(Inline),
    pending: *std.ArrayList(u8),
) !usize {
    const after = at + 1;
    const close = std.mem.indexOfScalarPos(u8, text, after, '>') orelse {
        try pending.append(a, '<');
        return after;
    };
    const address = text[after..close];
    if (!isAddress(address)) {
        try pending.append(a, '<');
        return after;
    }
    try emit(a, runs, pending, .plain);
    try appendText(a, pending, address);
    try emitLink(a, runs, pending, address);
    return close + 1;
}

/// Whether `inside` is an address a reader would recognise: a scheme, then
/// `://`, then something after it, with no space in the middle. A scheme is a
/// letter and then letters, digits, and the three marks URLs are written with.
fn isAddress(inside: []const u8) bool {
    const scheme = std.mem.indexOf(u8, inside, "://") orelse return false;
    if (scheme == 0 or scheme + 3 >= inside.len) return false;
    if (!std.ascii.isAlphabetic(inside[0])) return false;
    for (inside[0..scheme]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    for (inside[scheme..]) |c| {
        if (std.ascii.isWhitespace(c) or c == '<') return false;
    }
    return true;
}

/// Finish a link: the words collected in `pending`, and the address they point
/// at. The two are separate allocations even when they hold the same bytes, so
/// the run owns exactly what `releaseBlock` gives back.
fn emitLink(a: Allocator, runs: *std.ArrayList(Inline), pending: *std.ArrayList(u8), destination: []const u8) !void {
    if (pending.items.len == 0) return;
    const text = try a.dupe(u8, pending.items);
    errdefer a.free(text);
    const address = try own(a, destination);
    errdefer release(a, address);
    try runs.append(a, .{ .kind = .link, .text = text, .destination = address });
    pending.clearRetainingCapacity();
}

/// The start of the run that closes an emphasis or a strike opened at `from`,
/// or null when there is none. A closer is at least as long as the opener, has
/// text in front of it that does not end in a space, and - for an underscore -
/// is not followed by a word character.
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

test "a table arrives as rows, cells, and the alignments of its columns" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "| Name | Value | Note |\n| :--- | ---: | :--: |\n| one | 1 | first |\n| two | 2 | second |\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const table = blocks[0];
    try std.testing.expectEqual(BlockKind.table, table.kind);
    // A cell is plain text, so a table holds no inline runs of its own.
    try std.testing.expectEqual(@as(usize, 0), table.inlines.len);

    const header = [_][]const u8{ "Name", "Value", "Note" };
    const first = [_][]const u8{ "one", "1", "first" };
    const second = [_][]const u8{ "two", "2", "second" };
    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    // The header is the first row; what follows is the body in document order.
    try expectRow(table.rows[0], &header);
    try expectRow(table.rows[1], &first);
    try expectRow(table.rows[2], &second);

    const expected = [_]Align{ .left, .right, .center };
    try std.testing.expectEqualSlices(Align, &expected, table.aligns);

    // The source is kept whole, for a drawer with no room to draw columns in.
    try std.testing.expectEqualStrings(
        "| Name | Value | Note |\n| :--- | ---: | :--: |\n| one | 1 | first |\n| two | 2 | second |",
        table.text,
    );
}

test "a bare delimiter cell is left, the way GFM draws it" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "| a | b | c | d |\n| --- | :--- | :--: | ---: |\n| 1 | 2 | 3 | 4 |\n");
    defer deinit(blocks, a);

    const expected = [_]Align{ .left, .left, .center, .right };
    try std.testing.expectEqualSlices(Align, &expected, blocks[0].aligns);
}

test "a table needs no pipe at either edge of a row" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "name | value\n--- | ---\none | 1\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(BlockKind.table, blocks[0].kind);
    const header = [_][]const u8{ "name", "value" };
    const body = [_][]const u8{ "one", "1" };
    try expectRow(blocks[0].rows[0], &header);
    try expectRow(blocks[0].rows[1], &body);
}

test "a table with no body rows is still a table" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "| Column |\n| --- |\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.table, blocks[0].kind);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].rows.len);
    try expectRow(blocks[0].rows[0], &.{"Column"});
    try std.testing.expectEqual(@as(usize, 1), blocks[0].aligns.len);
    try std.testing.expectEqual(Align.left, blocks[0].aligns[0]);
}

test "a table ends where its columns do" {
    const a = std.testing.allocator;
    // A table may start right under prose, and the first line without a pipe
    // of its own is the block after it rather than a one-cell row.
    const blocks = try parse(a, "Here is the comparison:\n| a | b |\n| --- | --- |\n| 1 | 2 |\nAnd that is all.\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[0].kind);
    try std.testing.expectEqualStrings("Here is the comparison:", blocks[0].text);
    try std.testing.expectEqual(BlockKind.table, blocks[1].kind);
    try std.testing.expectEqual(@as(usize, 2), blocks[1].rows.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[2].kind);
    try std.testing.expectEqualStrings("And that is all.", blocks[2].text);
}

test "a pipe in a paragraph with no delimiter row is a paragraph" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "the regex is `a|b` and the choice is x | y\n\na | b\nc | d\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[0].kind);
    // Two pipe-bearing lines with nothing between them are still one paragraph.
    try std.testing.expectEqual(BlockKind.paragraph, blocks[1].kind);
    try std.testing.expectEqualStrings("a | b c | d", blocks[1].text);
}

test "a line under a pipe line is a table only when it delimits one" {
    const a = std.testing.allocator;
    // The delimiter row has a column the header has not, so neither line is a
    // table row and nothing is dropped.
    const mismatched = try parse(a, "| a | b |\n| --- | --- | --- |\n");
    defer deinit(mismatched, a);
    try std.testing.expectEqual(@as(usize, 1), mismatched.len);
    try std.testing.expectEqual(BlockKind.paragraph, mismatched[0].kind);

    // A bare `---` under a pipe line is a rule, not the delimiter row of a
    // one-column table: a delimiter row carries a pipe of its own.
    const ruled = try parse(a, "total | 3\n---\n");
    defer deinit(ruled, a);
    try std.testing.expectEqual(@as(usize, 2), ruled.len);
    try std.testing.expectEqual(BlockKind.paragraph, ruled[0].kind);
    try std.testing.expectEqual(BlockKind.rule, ruled[1].kind);
}

test "an escaped pipe is a cell's text, not a cell's edge" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "| pattern | meaning |\n| --- | --- |\n| ^a\\|b$ | either line |\n");
    defer deinit(blocks, a);

    const body = [_][]const u8{ "^a|b$", "either line" };
    try std.testing.expectEqual(@as(usize, 2), blocks[0].rows[1].len);
    try expectRow(blocks[0].rows[1], &body);

    // The header is split by the same rule, and a row that ends in an escaped
    // pipe keeps it instead of losing it to the row's edge.
    const header = try parse(a, "| a\\|b | c |\n| --- | --- |\n");
    defer deinit(header, a);
    const header_cells = [_][]const u8{ "a|b", "c" };
    try expectRow(header[0].rows[0], &header_cells);

    const ended = try parse(a, "| x | y \\|\n| --- | --- |\n");
    defer deinit(ended, a);
    const ended_cells = [_][]const u8{ "x", "y |" };
    try expectRow(ended[0].rows[0], &ended_cells);
}

test "a ragged row is kept as written, and an empty cell is a cell" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "| a | b | c |\n| --- | --- | --- |\n| short |\n| one | two | three | four |\n");
    defer deinit(blocks, a);

    const table = blocks[0];
    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    try std.testing.expectEqual(@as(usize, 1), table.rows[1].len);
    try std.testing.expectEqualStrings("short", table.rows[1][0]);
    try std.testing.expectEqual(@as(usize, 4), table.rows[2].len);
    try std.testing.expectEqualStrings("four", table.rows[2][3]);
    // The columns are the ones the delimiter row named, whatever a row holds.
    try std.testing.expectEqual(@as(usize, 3), table.aligns.len);

    const gap = try parse(a, "| a | b |\n| --- | --- |\n|  | 2 |\n");
    defer deinit(gap, a);
    try std.testing.expectEqual(@as(usize, 2), gap[0].rows[1].len);
    try std.testing.expectEqualStrings("", gap[0].rows[1][0]);
    try std.testing.expectEqualStrings("2", gap[0].rows[1][1]);
}

test "a CRLF table is the same table" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "| a | b |\r\n| --- | :--: |\r\n| 1 | 2 |\r\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(BlockKind.table, blocks[0].kind);
    const header = [_][]const u8{ "a", "b" };
    const body = [_][]const u8{ "1", "2" };
    try expectRow(blocks[0].rows[0], &header);
    try expectRow(blocks[0].rows[1], &body);
    try std.testing.expectEqual(Align.center, blocks[0].aligns[1]);
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

    // A display block goes through the same bound, and the body it was read
    // into belongs to the block that was refused.
    var mathematics: std.ArrayList(u8) = .empty;
    defer mathematics.deinit(a);
    for (0..max_blocks + 1) |_| try mathematics.appendSlice(a, "$$\nx\n$$\n");
    try std.testing.expectError(error.TooManyBlocks, parse(a, mathematics.items));
}

test "a struck run keeps its words and drops the tildes" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "keep ~~the old plan~~ and this\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try expectRun(runs[0], .plain, "keep ");
    try expectRun(runs[1], .strike, "the old plan");
    try expectRun(runs[2], .plain, " and this");
}

test "an unpaired tilde stays the character it was written as" {
    const a = std.testing.allocator;
    // An opened pair with no closer is text, and the rest of the line is still
    // the rest of the line; a single tilde is a path, not a mark.
    const blocks = try parse(a, "a ~~b and ~/.cache stay put\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try expectRun(runs[0], .plain, "a ~~b and ~/.cache stay put");
}

test "a link keeps its words and its address" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "see [the manual](https://example.com/docs) first\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 4), runs.len);
    try expectRun(runs[0], .plain, "see ");
    try expectLink(runs[1], "the manual", "https://example.com/docs");
    // The address is shown after the words, because a transcript nobody can
    // click still has to say where a link goes.
    try expectRun(runs[2], .link_url, "(https://example.com/docs)");
    try expectRun(runs[3], .plain, " first");

    // The words of a link are prose and decode like prose; the address is
    // followed rather than read, so it keeps the bytes the agent wrote.
    const encoded = try parse(a, "[the &amp; the](https://example.com/?a=1&amp;b=2)\n");
    defer deinit(encoded, a);
    const encoded_runs = encoded[0].inlines;
    try std.testing.expectEqual(@as(usize, 2), encoded_runs.len);
    try expectLink(encoded_runs[0], "the & the", "https://example.com/?a=1&amp;b=2");
    try expectRun(encoded_runs[1], .link_url, "(https://example.com/?a=1&amp;b=2)");

    // An autolink shows the address once, which is a comparison of what was
    // written rather than of what is drawn.
    const entity = try parse(a, "<https://example.com/?a=1&amp;b=2>\n");
    defer deinit(entity, a);
    try std.testing.expectEqual(@as(usize, 1), entity[0].inlines.len);
    try expectLink(entity[0].inlines[0], "https://example.com/?a=1&b=2", "https://example.com/?a=1&amp;b=2");
}

test "a link whose words are already its address is shown once" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "read <https://example.com/docs> now\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try expectRun(runs[0], .plain, "read ");
    try expectLink(runs[1], "https://example.com/docs", "https://example.com/docs");
    try expectRun(runs[2], .plain, " now");

    const spelled = try parse(a, "[https://example.com/docs](https://example.com/docs)\n");
    defer deinit(spelled, a);
    try std.testing.expectEqual(@as(usize, 1), spelled[0].inlines.len);
    try expectLink(spelled[0].inlines[0], "https://example.com/docs", "https://example.com/docs");

    // An angle bracket that is not an address is the bracket it was written as.
    const tag = try parse(a, "the <div> element and a < b\n");
    defer deinit(tag, a);
    try std.testing.expectEqual(@as(usize, 1), tag[0].inlines.len);
    try expectRun(tag[0].inlines[0], .plain, "the <div> element and a < b");
}

test "a link's words and address are read around brackets and parentheses" {
    const a = std.testing.allocator;
    // The words may hold brackets, the address may hold parentheses, and a
    // title after the address is not part of it.
    const blocks = try parse(a, "[c [d]](https://example.com/a_(b) \"Title\")\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try expectLink(runs[0], "c [d]", "https://example.com/a_(b)");
    try expectRun(runs[1], .link_url, "(https://example.com/a_(b))");
}

test "a bracket in a code span is code, not a link" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "run `[a](b)` and `x < y` now\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 5), runs.len);
    try expectRun(runs[0], .plain, "run ");
    try expectRun(runs[1], .code, "[a](b)");
    try expectRun(runs[2], .plain, " and ");
    try expectRun(runs[3], .code, "x < y");
    try expectRun(runs[4], .plain, " now");
}

test "a bracket with no link around it is text" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "an array [index] and [half a link](nowhere\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try expectRun(runs[0], .plain, "an array [index] and [half a link](nowhere");
}

test "the named entities decode to the characters they name" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "a&nbsp;b &lt;&gt;&quot;&apos;&amp; &AMP;\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try expectRun(runs[0], .plain, "a\u{a0}b <>\"'& &");
}

test "a non-breaking space is not the space a line breaks at" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "10&nbsp;MB and 10 MB\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    // `&nbsp;` is U+00A0 and not the byte a wrapper breaks a row at, so the
    // measured pair stays one word while the space after `and` is a break.
    try std.testing.expect(std.mem.startsWith(u8, runs[0].text, "10\u{a0}MB"));
    try std.testing.expect(std.mem.indexOf(u8, runs[0].text, "and 10 MB") != null);
}

test "numeric entities decode in both bases" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "&#65;&#x42; &#X1F600; &amp;#65;\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    // The replacement is not read again: `&amp;#65;` is an ampersand and four
    // characters, which is what makes one pass enough.
    try expectRun(runs[0], .plain, "AB \u{1f600} &#65;");
}

test "an entity that names nothing stays as written" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "&foo; &amp and &#x; and &#1114112; here\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try expectRun(runs[0], .plain, "&foo; &amp and &#x; and &#1114112; here");
}

test "an entity inside a styled run is decoded too" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "**a &amp; b** and `&amp;` and ~~c &lt; d~~\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 5), runs.len);
    try expectRun(runs[0], .bold, "a & b");
    try expectRun(runs[1], .plain, " and ");
    // Code is literal, which is why an agent writes a span for one.
    try expectRun(runs[2], .code, "&amp;");
    try expectRun(runs[3], .plain, " and ");
    try expectRun(runs[4], .strike, "c < d");
}

test "a sentence holding every inline reads back in order" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "shipped ~~v1~~ now, see [the plan](https://example.com/plan) for &lt;details&gt;\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 6), runs.len);
    try expectRun(runs[0], .plain, "shipped ");
    try expectRun(runs[1], .strike, "v1");
    try expectRun(runs[2], .plain, " now, see ");
    try expectLink(runs[3], "the plan", "https://example.com/plan");
    try expectRun(runs[4], .link_url, "(https://example.com/plan)");
    try expectRun(runs[5], .plain, " for <details>");
}

test "a dollar span in a sentence is a formula, and its neighbours are prose" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "the area is $\\pi r^2$ exactly\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try expectRun(runs[0], .plain, "the area is ");
    // The body is verbatim: the delimiters are gone and the LaTeX is not the
    // reader's to interpret.
    try expectRun(runs[1], .math, "\\pi r^2");
    try expectRun(runs[2], .plain, " exactly");
}

test "the prices in a sentence are not formulas" {
    const a = std.testing.allocator;
    // The closer is preceded by a space, which is the whole reason this is a
    // sentence: every second dollar in agent prose is a price.
    const prose = try parse(a, "it cost $5 and $10 in total\n");
    defer deinit(prose, a);
    try std.testing.expectEqual(@as(usize, 1), prose[0].inlines.len);
    try expectRun(prose[0].inlines[0], .plain, "it cost $5 and $10 in total");

    // A closer followed by a digit is currency too, so there is no span here
    // even though the whitespace rules are satisfied.
    const glued = try parse(a, "$5$10 and the rest\n");
    defer deinit(glued, a);
    try std.testing.expectEqual(@as(usize, 1), glued[0].inlines.len);
    try expectRun(glued[0].inlines[0], .plain, "$5$10 and the rest");

    // An opener followed by a space opens nothing, so `$ 5 $` is prose twice
    // over: once at the opener and once at the closer that has no opener.
    const spaced = try parse(a, "a $ 5 $ b\n");
    defer deinit(spaced, a);
    try std.testing.expectEqual(@as(usize, 1), spaced[0].inlines.len);
    try expectRun(spaced[0].inlines[0], .plain, "a $ 5 $ b");
}

test "a dollar that opens nothing stays the character it was written as" {
    const a = std.testing.allocator;
    // A lone dollar, an opener with no closer, and a closer with no opener all
    // stay where they were written rather than swallowing the line.
    const alone = try parse(a, "the price is $5\n");
    defer deinit(alone, a);
    try std.testing.expectEqual(@as(usize, 1), alone[0].inlines.len);
    try expectRun(alone[0].inlines[0], .plain, "the price is $5");

    const bare = try parse(a, "a $ b\n");
    defer deinit(bare, a);
    try std.testing.expectEqual(@as(usize, 1), bare[0].inlines.len);
    try expectRun(bare[0].inlines[0], .plain, "a $ b");

    // Whitespace is not a body.
    const blank = try parse(a, "a $ $ b\n");
    defer deinit(blank, a);
    try std.testing.expectEqual(@as(usize, 1), blank[0].inlines.len);
    try expectRun(blank[0].inlines[0], .plain, "a $ $ b");

    // A `$` at the end of a line has nothing after it to open with.
    const ended = try parse(a, "the total is $\n");
    defer deinit(ended, a);
    try std.testing.expectEqual(@as(usize, 1), ended[0].inlines.len);
    try expectRun(ended[0].inlines[0], .plain, "the total is $");
}

test "an escaped dollar is a literal, and an escaped closer does not close" {
    const a = std.testing.allocator;
    const escaped = try parse(a, "costs \\$5 today\n");
    defer deinit(escaped, a);
    try std.testing.expectEqual(@as(usize, 1), escaped[0].inlines.len);
    try expectRun(escaped[0].inlines[0], .plain, "costs $5 today");

    // `\$` inside the body is body text, so the span runs on to the real
    // closer, which is the last dollar on the line.
    const inside = try parse(a, "$a \\$ b$ and $c$\n");
    defer deinit(inside, a);
    const runs = inside[0].inlines;
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try expectRun(runs[0], .math, "a \\$ b");
    try expectRun(runs[1], .plain, " and ");
    try expectRun(runs[2], .math, "c");
}

test "the bracket and double-dollar forms are formulas too" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "so \\(x+1\\) and $$y^2$$ and \\[z\\] end\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 7), runs.len);
    try expectRun(runs[0], .plain, "so ");
    try expectRun(runs[1], .math, "x+1");
    try expectRun(runs[2], .plain, " and ");
    try expectRun(runs[3], .math, "y^2");
    try expectRun(runs[4], .plain, " and ");
    // `\[z\]` on one line is a span like the rest: it is the own-line form that
    // makes a block, not the delimiter.
    try expectRun(runs[5], .math, "z");
    try expectRun(runs[6], .plain, " end");
}

test "a bracket opener with no closer falls back to the escape it looks like" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "a \\(b and a \\[c here\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    // Nothing is swallowed: an unclosed opener is the escaped bracket, which is
    // what the same characters mean without a closer in sight.
    try expectRun(runs[0], .plain, "a (b and a [c here");
}

test "a `$$` written inside a sentence is a span, not a block" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "the value is $$x^2$$ here\n");
    defer deinit(blocks, a);

    // A block is a delimiter alone on its line; this line has words around it,
    // so it stays one paragraph with one display-shaped span in it.
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[0].kind);
    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try expectRun(runs[0], .plain, "the value is ");
    try expectRun(runs[1], .math, "x^2");
    try expectRun(runs[2], .plain, " here");
}

test "a dollar inside a code span is code, not a formula" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "the shell is `echo $HOME` and $x$ is a formula\n");
    defer deinit(blocks, a);

    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 5), runs.len);
    try expectRun(runs[0], .plain, "the shell is ");
    try expectRun(runs[1], .code, "echo $HOME");
    try expectRun(runs[2], .plain, " and ");
    try expectRun(runs[3], .math, "x");
    try expectRun(runs[4], .plain, " is a formula");
}

test "a display block is the formula with its delimiters taken off" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "$$\nE = mc^2\n$$\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.math, blocks[0].kind);
    try std.testing.expectEqualStrings("E = mc^2", blocks[0].text);
    try std.testing.expectEqual(@as(usize, 0), blocks[0].inlines.len);
    try std.testing.expectEqual(@as(u8, 0), blocks[0].level);

    // A display block is line-oriented, so a CRLF transcript has the same one
    // as an LF transcript.
    const crlf = try parse(a, "$$\r\nE = mc^2\r\n$$\r\n");
    defer deinit(crlf, a);
    try std.testing.expectEqual(BlockKind.math, crlf[0].kind);
    try std.testing.expectEqualStrings("E = mc^2", crlf[0].text);

    // The bracket form opens and closes on its own lines the same way.
    const bracket = try parse(a, "\\[\nx^2\n\\]\n");
    defer deinit(bracket, a);
    try std.testing.expectEqual(BlockKind.math, bracket[0].kind);
    try std.testing.expectEqualStrings("x^2", bracket[0].text);
}

test "a display block keeps the lines and the blank lines inside it" {
    const a = std.testing.allocator;
    // A matrix is `\\` row breaks and `&` alignment, and a blank line in the
    // middle of one is still part of it - which is why the block is read at the
    // block level rather than by the paragraph reader.
    const matrix = try parse(a, "text before\n\n$$\n\\begin{matrix}\na & b \\\\\n\nc & d\n\\end{matrix}\n$$\n\ntext after\n");
    defer deinit(matrix, a);

    try std.testing.expectEqual(@as(usize, 3), matrix.len);
    try std.testing.expectEqualStrings("text before", matrix[0].text);
    try std.testing.expectEqual(BlockKind.math, matrix[1].kind);
    try std.testing.expectEqualStrings("\\begin{matrix}\na & b \\\\\n\nc & d\n\\end{matrix}", matrix[1].text);
    try std.testing.expectEqualStrings("text after", matrix[2].text);

    // A closer may carry the whitespace a wrapper left after it.
    const spaced = try parse(a, "$$\nx\n$$  \n");
    defer deinit(spaced, a);
    try std.testing.expectEqual(BlockKind.math, spaced[0].kind);
    try std.testing.expectEqualStrings("x", spaced[0].text);
}

test "a display opener with no closer is two characters, not a swallowed message" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "$$\nthis line is not a formula\n");
    defer deinit(blocks, a);

    // The opener never closes, so the lines are the paragraph they were and the
    // `$$` is the text the reader shows.
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[0].kind);
    try std.testing.expectEqualStrings("$$ this line is not a formula", blocks[0].text);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].inlines.len);
    try expectRun(blocks[0].inlines[0], .plain, "$$ this line is not a formula");

    // `$$` over `$$` is an empty block, which is not a block.
    const empty = try parse(a, "$$\n$$\n");
    defer deinit(empty, a);
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    try std.testing.expectEqual(BlockKind.paragraph, empty[0].kind);
    try std.testing.expectEqualStrings("$$ $$", empty[0].text);
}

test "a bare math environment is a display block, wrappers and all" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "\\begin{align}\nx &= 1 \\\\\ny &= 2\n\\end{align}\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(BlockKind.math, blocks[0].kind);
    // The wrappers are part of the formula, so they stay: they are what says
    // which environment the rows belong to.
    try std.testing.expectEqualStrings("\\begin{align}\nx &= 1 \\\\\ny &= 2\n\\end{align}", blocks[0].text);

    // The starred variant is the same environment, and it closes with the name
    // it opened with.
    const starred = try parse(a, "\\begin{align*}\na &= b\n\\end{align*}\n");
    defer deinit(starred, a);
    try std.testing.expectEqual(BlockKind.math, starred[0].kind);
    try std.testing.expectEqualStrings("\\begin{align*}\na &= b\n\\end{align*}", starred[0].text);
}

test "a bare environment that is prose stays prose" {
    const a = std.testing.allocator;
    // `itemize` is not a math environment, so the wrappers are the text they
    // look like and nothing is converted.
    const list = try parse(a, "\\begin{itemize}\n\\item one\n\\end{itemize}\n");
    defer deinit(list, a);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(BlockKind.paragraph, list[0].kind);

    // A blank line ends the paragraph the environment was written as, and the
    // `\begin` that never closes inside it is not a block.
    const broken = try parse(a, "\\begin{align}\nx &= 1\n\n\\end{align}\n");
    defer deinit(broken, a);
    try std.testing.expectEqual(@as(usize, 2), broken.len);
    try std.testing.expectEqual(BlockKind.paragraph, broken[0].kind);
    try std.testing.expectEqualStrings("\\begin{align} x &= 1", broken[0].text);
    try std.testing.expectEqual(BlockKind.paragraph, broken[1].kind);

    // An environment inside a fence is code: a fence is read before anything
    // else on its line, and the lines under it belong to it.
    const fenced = try parse(a, "```latex\n\\begin{align}\nx &= 1\n\\end{align}\n```\n");
    defer deinit(fenced, a);
    try std.testing.expectEqual(@as(usize, 1), fenced.len);
    try std.testing.expectEqual(BlockKind.code, fenced[0].kind);
    try std.testing.expectEqualStrings("\\begin{align}\nx &= 1\n\\end{align}", fenced[0].text);
}

test "a paragraph holding a formula and a block holding one read back in order" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "The energy is $E = mc^2$ for a mass $m$.\n\n$$\na = b\n$$\n");
    defer deinit(blocks, a);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    const runs = blocks[0].inlines;
    try std.testing.expectEqual(@as(usize, 5), runs.len);
    try expectRun(runs[0], .plain, "The energy is ");
    try expectRun(runs[1], .math, "E = mc^2");
    try expectRun(runs[2], .plain, " for a mass ");
    try expectRun(runs[3], .math, "m");
    try expectRun(runs[4], .plain, ".");
    try std.testing.expectEqual(BlockKind.math, blocks[1].kind);
    try std.testing.expectEqualStrings("a = b", blocks[1].text);
}

test "an ordered item keeps the number it was written with" {
    const a = std.testing.allocator;
    const blocks = try parse(a, "10. tenth\n11) eleventh\n");
    defer deinit(blocks, a);

    // An ordered marker is part of the item's own text, so nothing has to be
    // remembered anywhere else for the list to draw as ordered.
    try std.testing.expectEqual(BlockKind.bullet, blocks[0].kind);
    try std.testing.expectEqualStrings("10. tenth", blocks[0].text);
    try std.testing.expectEqualStrings("11) eleventh", blocks[1].text);
}

fn expectRun(run: Inline, kind: InlineKind, text: []const u8) !void {
    try std.testing.expectEqual(kind, run.kind);
    try std.testing.expectEqualStrings(text, run.text);
}

fn expectLink(run: Inline, text: []const u8, destination: []const u8) !void {
    try std.testing.expectEqual(InlineKind.link, run.kind);
    try std.testing.expectEqualStrings(text, run.text);
    try std.testing.expectEqualStrings(destination, run.destination);
}

fn expectRow(row: Row, cells: []const []const u8) !void {
    try std.testing.expectEqual(cells.len, row.len);
    for (cells, row) |want, got| try std.testing.expectEqualStrings(want, got);
}
