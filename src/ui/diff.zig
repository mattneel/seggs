//! Reading a unified diff.
//!
//! An agent's transcript carries diffs the way `git diff` prints them, and
//! drawing one as wrapped text throws away the only structure it has: which
//! file it is about, where a hunk begins, and which lines were added and which
//! were removed. This turns those bytes into exactly that structure and
//! nothing else - no line numbers, and no pairing of a removed line with the
//! added one that replaced it, because this reads the list the diff wrote and a
//! pairing nobody asked for would be a second thing to be wrong about. Pairing
//! is the drawer's to decide; `wordDiff` is what it asks once it has decided,
//! and the answer is the words of that pair that differ.
//!
//! A `Line` is the line as the diff wrote it, prefix and all. The prefix is
//! what the kind is read from, and it stays in the text so a renderer draws
//! what it is given and colours it by kind without re-reading any of it.
//!
//! It is a reader for the shape of a unified diff, not for everything a patch
//! can carry: the meta lines outside a hunk - `index`, a mode change,
//! `similarity index`, `Binary files` - are what says where one file's section
//! ends and the next begins, and are not kept, because nothing draws them.
//!
//! A word diff goes the other way about ownership: it is handed two lines and
//! hands back spans that point into them, so the two arrays are all it
//! allocates and the caller's bytes are all it reads.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The most bytes `parse` will read. A transcript hands over one code block,
/// and a code block past this is not a diff anybody is reading.
pub const max_bytes: usize = 1 << 20;

/// The most file sections `parse` will read.
pub const max_files: usize = 4096;

/// The most words one side of a word diff may carry. A line with more than
/// this is not a line anybody edits a word of, and a pair of them is a pair to
/// read as two whole lines.
pub const max_words: usize = 4096;

/// How many lines `looksLikeDiff` inspects before it makes up its mind. A diff
/// says what it is in its first line or two; a line further down that happens
/// to look like one is a line of prose.
const lookahead_lines: usize = 8;

/// `diff --git a/x b/x` opens a section in every diff git writes.
const git_line = "diff --git ";

/// The old-side file header, which a `diff -u` diff opens a section with.
const minus_header = "--- ";

/// The new-side file header, which names the path that section is about.
const plus_header = "+++ ";

/// The kinds a line of a diff has, which is the vocabulary an interface
/// colours by. `hunk` names the `@@` line that opens a hunk: it is a line of
/// the diff like any other, but its text is `Hunk.header` rather than an entry
/// in `Hunk.lines`, because a hunk's header is a field of the hunk it opens.
pub const LineKind = enum { meta, hunk, context, added, removed };

/// One line of a hunk, as the diff wrote it: an added line carries its `+`,
/// a removed one its `-`, and a context line the space that keeps the columns
/// of a unified diff lined up.
pub const Line = struct { kind: LineKind, text: []const u8 };

pub const Hunk = struct {
    /// The whole `@@` line, which is what a reader recognises a hunk by. It is
    /// not repeated as the first `Line`: the text lives here, and the numbers
    /// on it are never parsed into anything the interface draws.
    header: []const u8,
    /// The body in the order the diff carries it, the `\ No newline at end of
    /// file` marker included.
    lines: []const Line,
};

pub const File = struct {
    /// The path from the `+++` line, or the `diff --git` line when there is
    /// no `+++`, or empty. It is the path as the diff writes it, `b/` prefix
    /// and all, because that is what the line says. `/dev/null` is the format
    /// saying there is no path rather than naming one, so a `+++` line
    /// carrying it leaves the `diff --git` line answering instead.
    path: []const u8,
    hunks: []const Hunk,
};

/// Parse a unified diff. Null when the bytes are not one - the caller uses
/// this to decide whether to draw a code block as a diff at all.
///
/// Every slice in the result is a copy from `a`, so nothing borrows `bytes`
/// and `deinit` releases all of it. Reading no bytes at all is an empty slice
/// rather than null: an empty code block is an empty diff, not prose.
///
/// Errors are `error.DiffTooLarge` and `error.TooManyFiles` past the bounds
/// above, and `error.MalformedDiff` for bytes that claim to be a diff and are
/// not one - a line opening a hunk header that is not a hunk header.
pub fn parse(a: Allocator, bytes: []const u8) !?[]File {
    if (bytes.len > max_bytes) return error.DiffTooLarge;
    if (bytes.len == 0) return try a.alloc(File, 0);

    // A draft borrows `bytes` while the diff is being read, so only the arrays
    // it grows are allocated and a malformed diff fails with nothing to undo.
    // The copy into the caller's allocator happens once, at the end, when the
    // shape of the result is known.
    var drafts: std.ArrayList(Draft) = .empty;
    defer {
        for (drafts.items) |*draft| draft.deinit(a);
        drafts.deinit(a);
    }

    var lines = Lines{ .bytes = bytes };
    var recognized = false;
    var in_hunk = false;
    // What the open hunk's header declares is still to come, old side and new
    // side. It is the format's own statement of where the body ends, which is
    // what tells a blank line inside the hunk from the blank line after it.
    var old_left: usize = 0;
    var new_left: usize = 0;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, git_line)) {
            // The one line that says a new section starts with no ambiguity at
            // all: git writes it for every file, even one whose diff carries
            // no hunks, and the path on it answers for a section whose `+++`
            // line never arrives.
            in_hunk = false;
            if (gitPath(line)) |path| {
                try beginSection(a, &drafts, .{ .git = path });
                recognized = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, minus_header) and lines.startsWith(plus_header)) {
            // `--- a/x` over `+++ b/x` is how every other diff opens a
            // section, and neither line means anything alone: a `---` on its
            // own is a removed line whose content starts with `--`, and a
            // `+++` on its own is an added line whose content starts with
            // `++`. Only the pair says a file starts here.
            in_hunk = false;
            const section = if (drafts.items.len > 0 and !drafts.items[drafts.items.len - 1].header_done)
                &drafts.items[drafts.items.len - 1]
            else open: {
                try beginSection(a, &drafts, .{});
                break :open &drafts.items[drafts.items.len - 1];
            };
            // The path is on the second line of the pair, which is the line
            // under this one. A deletion's `+++` names `/dev/null`, which is
            // the format saying there is no post-image path rather than naming
            // one, so the `diff --git` line answers for it.
            if (plusPath(lines.peek().?)) |path| section.path = path;
            section.header_done = true;
            recognized = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "@@")) {
            // Every other line of a diff has a prefix that says what it is;
            // this one is the shape a hunk header has, and the counts are the
            // only thing read off it.
            const sides = hunkSides(line) orelse return error.MalformedDiff;
            if (drafts.items.len == 0) try beginSection(a, &drafts, .{});
            const draft = &drafts.items[drafts.items.len - 1];
            draft.header_done = true;
            try draft.hunks.append(a, .{ .header = line });
            old_left = sides.old;
            new_left = sides.new;
            in_hunk = true;
            recognized = true;
            continue;
        }
        if (in_hunk) {
            // A blank line inside a hunk is a context line whose one leading
            // space was stripped on the way into the transcript, which is what
            // a fence around a diff does to it. It is only one while the hunk
            // still declares body lines, so the blank line after the last of
            // them stays what it is: the space between two sections.
            const declared = old_left > 0 or new_left > 0;
            const kind: ?LineKind = if (line.len == 0)
                (if (declared) LineKind.context else null)
            else
                bodyKind(line);
            if (kind) |k| {
                try openHunk(&drafts).lines.append(a, .{ .kind = k, .text = line });
                switch (k) {
                    .context => {
                        old_left -|= 1;
                        new_left -|= 1;
                    },
                    .removed => old_left -|= 1,
                    .added => new_left -|= 1,
                    // The marker says something about a line rather than
                    // being one, so it counts against neither side.
                    .meta, .hunk => {},
                }
                continue;
            }
            // A body is contiguous: the first line that is not one of the
            // shapes a body line has ends the hunk, whatever it turns out to
            // be. A line that ends one is read by the top of the loop, so a
            // `diff --git` or a `@@` right after a body is not lost here.
            in_hunk = false;
        }
        // Everything else is a meta line - index, mode, similarity, rename,
        // `Binary files`, or a file header whose pair never came - and carries
        // no structure anything draws.
    }

    if (!recognized) return null;

    // The shape is known, so this is where the one copy happens: every slice
    // handed back comes from `a` and outlives `bytes`.
    const files = try a.alloc(File, drafts.items.len);
    var built: usize = 0;
    errdefer {
        for (files[0..built]) |file| freeFile(file, a);
        a.free(files);
    }
    for (drafts.items, files) |*draft, *file| {
        file.* = try materialize(a, draft);
        built += 1;
    }
    return files;
}

/// Release a parsed diff. `a` is the allocator it was parsed with.
pub fn deinit(files: []File, a: Allocator) void {
    for (files) |file| freeFile(file, a);
    a.free(files);
}

/// Whether this looks like a unified diff, judged from its first lines only.
/// Cheap, and deliberately not a parse: a transcript decides with this and
/// parses only what passes.
///
/// The evidence is a `diff --git` line, a `---` header with a `+++` under it,
/// or a hunk header: prose that merely contains lines starting with `-` or `+`
/// is a bullet list, and neither of those openers is worth anything on its own.
pub fn looksLikeDiff(bytes: []const u8) bool {
    var lines = Lines{ .bytes = bytes };
    var minus = false;
    var seen: usize = 0;
    while (seen < lookahead_lines) : (seen += 1) {
        const line = lines.next() orelse break;
        if (std.mem.startsWith(u8, line, git_line) and gitPath(line) != null) return true;
        if (minus and std.mem.startsWith(u8, line, plus_header)) return true;
        if (std.mem.startsWith(u8, line, minus_header)) {
            minus = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "@@") and hunkSides(line) != null) return true;
        minus = false;
    }
    return false;
}

/// One run of a line's text, and whether the other line of the pair carries it.
/// The text is a slice of the line the run was read from, never a copy.
pub const Span = struct { text: []const u8, changed: bool };

/// A removed line and the added line that replaced it, each read as the runs
/// it is drawn in. The runs are in order and nothing is dropped: reading one
/// side's spans in turn gives back the line they were read from.
pub const WordDiff = struct { removed: []const Span, added: []const Span };

/// Mark what differs between a removed line and the added line that replaced
/// it, so that a reader is shown the words that changed rather than two whole
/// lines to compare. The lines are the pair as the caller paired them: this
/// does not decide which removed line went with which added one.
///
/// Null when the pair is not worth marking - a side with no words, or two
/// sides that share less than half of the longer one's words. Unrelated lines
/// are two whole lines and are drawn as two whole lines, because marks over
/// most of both say less than no marks at all, and a pairing that wrong is the
/// caller's to wear rather than the reader's to squint at. A pair that differs
/// only in whitespace, or not at all, comes back as a pair with nothing
/// changed.
///
/// A word is a run of non-whitespace bytes and the split is on ASCII
/// whitespace, so nothing here has to be text: bytes that are not UTF-8 are
/// split and compared like any others, and no run can begin or end inside a
/// character. A word is changed when the other line does not carry those exact
/// bytes, so `foo` and `Foo` are two words rather than one, and whitespace
/// joins the word before it, which keeps indentation out of the marks and puts
/// a changed word's trailing space inside its mark. That is all the marking a
/// word gets: "these words differ" is what a reader is served by, and an
/// alignment of the two sides would be a real diff nobody asked for.
///
/// The spans borrow `removed` and `added`, so those bytes have to outlive the
/// drawing of them; the two arrays the spans live in are this call's, and
/// `freeWordDiff` releases both. Errors are `error.DiffTooLarge` for a side
/// past `max_bytes` and `error.TooManyWords` for one past `max_words`.
pub fn wordDiff(a: Allocator, removed: []const u8, added: []const u8) !?WordDiff {
    if (removed.len > max_bytes or added.len > max_bytes) return error.DiffTooLarge;

    // Both vocabularies are needed at once: each side is marked against the
    // other, so neither can be thrown away after the guard.
    var removed_words = try words(a, removed);
    defer removed_words.deinit();
    var added_words = try words(a, added);
    defer added_words.deinit();

    // A side with no words is a line being written or one being dropped whole,
    // and neither is a rewrite of the other: the diff already says all there
    // is to say about it.
    if (removed_words.count() == 0 or added_words.count() == 0) return null;

    // How much of the pair the two lines have in common, judged by distinct
    // words rather than by their order, because order is exactly what a real
    // diff would be needed for and this is not one.
    var shared: usize = 0;
    var keys = removed_words.keyIterator();
    while (keys.next()) |word| {
        if (added_words.contains(word.*)) shared += 1;
    }
    const longer = @max(removed_words.count(), added_words.count());
    if (shared * 2 < longer) return null;

    const removed_spans = try markedSpans(a, removed, &added_words);
    errdefer a.free(removed_spans);
    const added_spans = try markedSpans(a, added, &removed_words);
    return .{ .removed = removed_spans, .added = added_spans };
}

/// Release a marked pair. `a` is the allocator `wordDiff` was called with. The
/// lines the spans point into belong to the caller and are not touched.
pub fn freeWordDiff(marked: WordDiff, a: Allocator) void {
    a.free(marked.removed);
    a.free(marked.added);
}

/// The words of one line, which is what marking against the other side asks
/// about: a word is its own bytes, and where it sat is what the spans are read
/// from. The keys borrow `line`.
const Words = std.StringHashMap(void);

/// Collect the words of `line`, which is the one place the word bound is
/// enforced: past it the pair is not a line pair anybody is reading.
fn words(a: Allocator, line: []const u8) !Words {
    var set = Words.init(a);
    errdefer set.deinit();
    var runs = Runs{ .line = line };
    var count: usize = 0;
    while (runs.next()) |run| {
        if (run.space) continue;
        if (count == max_words) return error.TooManyWords;
        count += 1;
        try set.put(run.text, {});
    }
    return set;
}

/// One line marked against the other side's words: its runs, merged into the
/// longest spans that share a mark, so a drawer gets the fewest spans a reader
/// can be shown. Whitespace takes the mark of the word before it, and the
/// whitespace before the first word takes no mark, which is what keeps
/// indentation - and a change to nothing but indentation - out of the marks.
fn markedSpans(a: Allocator, line: []const u8, other: *const Words) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(a);
    var runs = Runs{ .line = line };
    var start: usize = 0;
    var mark: ?bool = null;
    var after_word = false;
    while (runs.next()) |run| {
        const changed = if (run.space) after_word else !other.contains(run.text);
        if (mark == null or mark.? != changed) {
            // The run begins where the span before it ended, so the line up to
            // here is the span that just closed.
            if (mark != null) try spans.append(a, .{ .text = line[start..run.start], .changed = mark.? });
            start = run.start;
            mark = changed;
        }
        if (!run.space) after_word = changed;
    }
    if (mark) |changed| try spans.append(a, .{ .text = line[start..], .changed = changed });
    return spans.toOwnedSlice(a);
}

/// A run of a line: either a word or the whitespace between two words, and
/// where it begins. Every byte of the line is in exactly one of them.
const Run = struct { start: usize, text: []const u8, space: bool };

/// The bytes of a line, one run at a time. The split is on ASCII whitespace
/// only, so a run is a whole number of bytes between two whitespace bytes and
/// nothing here reads a byte of a character it did not look at.
const Runs = struct {
    line: []const u8,
    at: usize = 0,

    fn next(self: *Runs) ?Run {
        if (self.at >= self.line.len) return null;
        const space = std.ascii.isWhitespace(self.line[self.at]);
        var end = self.at;
        while (end < self.line.len and std.ascii.isWhitespace(self.line[end]) == space) end += 1;
        const run = Run{ .start = self.at, .text = self.line[self.at..end], .space = space };
        self.at = end;
        return run;
    }
};

/// A file section while it is being read. Its slices borrow `bytes`, which is
/// what `parse` copies out of once the whole diff has been read.
const Draft = struct {
    /// The path from the `+++` line, when the section carries one.
    path: ?[]const u8 = null,
    /// The path from the `diff --git` line, which `path` answers over.
    git: ?[]const u8 = null,
    hunks: std.ArrayList(DraftHunk) = .empty,
    /// Whether the `+++` line or a hunk has already been seen, which is what
    /// makes a later `---` the next section's header rather than this one's.
    header_done: bool = false,

    fn deinit(self: *Draft, a: Allocator) void {
        for (self.hunks.items) |*hunk| hunk.lines.deinit(a);
        self.hunks.deinit(a);
    }
};

/// A hunk while it is being read: the header and the lines borrow `bytes`.
const DraftHunk = struct {
    header: []const u8,
    lines: std.ArrayList(Line) = .empty,
};

/// Begin a section, refusing past the bound rather than growing without one.
fn beginSection(a: Allocator, drafts: *std.ArrayList(Draft), draft: Draft) !void {
    if (drafts.items.len == max_files) return error.TooManyFiles;
    try drafts.append(a, draft);
}

/// The hunk the next body line belongs to: the last one of the last section,
/// which is where the header that opened it put it.
fn openHunk(drafts: *std.ArrayList(Draft)) *DraftHunk {
    const draft = &drafts.items[drafts.items.len - 1];
    return &draft.hunks.items[draft.hunks.items.len - 1];
}

/// The post-image path on a `diff --git a/x b/x` line, which is the one a
/// reader is looking for. Null when the line names fewer than two paths, which
/// makes it prose that merely opens with the same words.
fn gitPath(line: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeScalar(u8, line[git_line.len..], ' ');
    _ = tokens.next() orelse return null;
    return tokens.next();
}

/// The path on a `+++` line: what follows the prefix up to the tab GNU diff
/// puts before the file's timestamp. `/dev/null` is the format's way of saying
/// there is no such path, so it reads as none.
fn plusPath(line: []const u8) ?[]const u8 {
    const rest = line[plus_header.len..];
    const path = if (std.mem.indexOfScalar(u8, rest, '\t')) |tab| rest[0..tab] else rest;
    return if (std.mem.eql(u8, path, "/dev/null")) null else path;
}

/// The kind of a line inside a hunk body, or null when it is not one of the
/// shapes a body line has - which is what ends the hunk. A blank line is not
/// in the vocabulary here because whether it is a line of the hunk at all is
/// the header's business, not the line's.
fn bodyKind(line: []const u8) ?LineKind {
    if (line.len == 0) return null;
    return switch (line[0]) {
        ' ' => .context,
        '+' => .added,
        '-' => .removed,
        // `\ No newline at end of file`, the one line of a body that is not
        // one of the file's lines.
        '\\' => .meta,
        else => null,
    };
}

/// The two side counts a hunk header declares, which is how many lines of the
/// old file and of the new one the body carries. Null when the line is not a
/// unified hunk header.
const Sides = struct { old: usize, new: usize };

fn hunkSides(line: []const u8) ?Sides {
    if (!std.mem.startsWith(u8, line, "@@ ")) return null;
    const old = hunkRange(line, "@@ ".len, '-') orelse return null;
    if (old.end >= line.len or line[old.end] != ' ') return null;
    const new = hunkRange(line, old.end + 1, '+') orelse return null;
    // Anything after the closing `@@` is the section heading git appends,
    // which is part of the line and none of the counts.
    if (!std.mem.startsWith(u8, line[new.end..], " @@")) return null;
    return .{ .old = old.count, .new = new.count };
}

/// One side of a hunk header read from `at`: `-1,3`, or `-1` where the count
/// is left out because it is one line.
const Range = struct { count: usize, end: usize };

fn hunkRange(line: []const u8, at: usize, sign: u8) ?Range {
    if (at >= line.len or line[at] != sign) return null;
    var index = at + 1;
    const start = index;
    while (index < line.len and std.ascii.isDigit(line[index])) index += 1;
    // The line number is read and dropped, and reading it is what refuses a
    // number too large to be one: a header whose numbers overflow is malformed
    // either way, and a count that did not fit would be a size not to trust.
    if (index == start) return null;
    _ = std.fmt.parseInt(usize, line[start..index], 10) catch return null;

    var count: usize = 1;
    if (index < line.len and line[index] == ',') {
        index += 1;
        const digits = index;
        while (index < line.len and std.ascii.isDigit(line[index])) index += 1;
        if (index == digits) return null;
        count = std.fmt.parseInt(usize, line[digits..index], 10) catch return null;
    }
    return .{ .count = count, .end = index };
}

/// Copy one section out of the bytes it was read from, so that everything the
/// result points at belongs to the caller's allocator.
fn materialize(a: Allocator, draft: *const Draft) !File {
    const path = try a.dupe(u8, draft.path orelse draft.git orelse "");
    // Guarded the moment it exists: the allocation under it can be the one
    // that gives up, and a path with nothing else copied yet still has to be
    // handed back.
    errdefer a.free(path);
    const hunks = try a.alloc(Hunk, draft.hunks.items.len);
    var built: usize = 0;
    errdefer {
        for (hunks[0..built]) |hunk| freeHunk(hunk, a);
        a.free(hunks);
    }
    for (draft.hunks.items, hunks) |src, *dest| {
        // The header and the line array come first, so that a failure part way
        // through a hunk has one thing to undo and `built` still covers every
        // hunk already handed over.
        const header = try a.dupe(u8, src.header);
        const lines = copyLines(a, src.lines.items) catch |err| {
            a.free(header);
            return err;
        };
        dest.* = .{ .header = header, .lines = lines };
        built += 1;
    }
    return .{ .path = path, .hunks = hunks };
}

/// The lines of one hunk, copied. A failure leaves nothing of the copy behind.
fn copyLines(a: Allocator, lines: []const Line) ![]Line {
    const copy = try a.alloc(Line, lines.len);
    var at: usize = 0;
    errdefer {
        for (copy[0..at]) |line| a.free(line.text);
        a.free(copy);
    }
    for (copy, lines) |*dest, src| {
        dest.* = .{ .kind = src.kind, .text = try a.dupe(u8, src.text) };
        at += 1;
    }
    return copy;
}

fn freeFile(file: File, a: Allocator) void {
    for (file.hunks) |hunk| freeHunk(hunk, a);
    a.free(file.hunks);
    a.free(file.path);
}

fn freeHunk(hunk: Hunk, a: Allocator) void {
    for (hunk.lines) |line| a.free(line.text);
    a.free(hunk.lines);
    a.free(hunk.header);
}

/// A line of the diff and where the next one begins.
const Text = struct { text: []const u8, next: usize };

/// The bytes of a diff, one line at a time. Newlines are not part of a line,
/// and neither is a trailing `\r`, so a diff that travelled through a CRLF
/// host reads like any other.
const Lines = struct {
    bytes: []const u8,
    at: usize = 0,

    fn lineAt(self: *const Lines, index: usize) Text {
        const stop = std.mem.indexOfScalarPos(u8, self.bytes, index, '\n') orelse self.bytes.len;
        const line = self.bytes[index..stop];
        return .{
            .text = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line,
            .next = @min(stop + 1, self.bytes.len),
        };
    }

    fn next(self: *Lines) ?[]const u8 {
        if (self.at >= self.bytes.len) return null;
        const found = self.lineAt(self.at);
        self.at = found.next;
        return found.text;
    }

    /// The next line, without consuming it. A file header is the one thing a
    /// diff cannot be read one line at a time: whether a `---` opens a section
    /// depends on the line under it, and that line is where the path is.
    fn peek(self: *const Lines) ?[]const u8 {
        if (self.at >= self.bytes.len) return null;
        return self.lineAt(self.at).text;
    }

    fn startsWith(self: *const Lines, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.peek() orelse return false, prefix);
    }
};

test "a diff of two files becomes two files with their hunks" {
    const a = std.testing.allocator;
    const bytes =
        \\diff --git a/one.zig b/one.zig
        \\index 1111111..2222222 100644
        \\--- a/one.zig
        \\+++ b/one.zig
        \\@@ -1,2 +1,3 @@
        \\ const std = @import("std");
        \\-const answer = 41;
        \\+const answer = 42;
        \\+const extra = true;
        \\@@ -20,2 +21,1 @@
        \\-const old = true;
        \\ const kept = true;
        \\diff --git a/two.txt b/two.txt
        \\similarity index 90%
        \\rename from two.txt
        \\rename to two.txt
        \\--- a/two.txt
        \\+++ b/two.txt
        \\@@ -1,1 +1,1 @@
        \\-one
        \\+two
        \\
    ;
    const files = (try parse(a, bytes)).?;
    defer deinit(files, a);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("b/one.zig", files[0].path);
    try std.testing.expectEqual(@as(usize, 2), files[0].hunks.len);
    try std.testing.expectEqualStrings("@@ -1,2 +1,3 @@", files[0].hunks[0].header);
    try std.testing.expectEqual(@as(usize, 4), files[0].hunks[0].lines.len);
    try std.testing.expectEqualStrings("@@ -20,2 +21,1 @@", files[0].hunks[1].header);
    try std.testing.expectEqual(@as(usize, 2), files[0].hunks[1].lines.len);

    try std.testing.expectEqualStrings("b/two.txt", files[1].path);
    try std.testing.expectEqual(@as(usize, 1), files[1].hunks.len);
    try std.testing.expectEqual(@as(usize, 2), files[1].hunks[0].lines.len);
}

test "a hunk body line is told apart by its prefix" {
    const a = std.testing.allocator;
    const bytes =
        \\--- a/keep.txt
        \\+++ b/keep.txt
        \\@@ -1,2 +1,2 @@
        \\ keep
        \\-drop
        \\+add
        \\\ No newline at end of file
        \\
    ;
    const files = (try parse(a, bytes)).?;
    defer deinit(files, a);

    const lines = files[0].hunks[0].lines;
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqual(LineKind.context, lines[0].kind);
    try std.testing.expectEqualStrings(" keep", lines[0].text);
    try std.testing.expectEqual(LineKind.removed, lines[1].kind);
    try std.testing.expectEqualStrings("-drop", lines[1].text);
    try std.testing.expectEqual(LineKind.added, lines[2].kind);
    try std.testing.expectEqualStrings("+add", lines[2].text);
    try std.testing.expectEqual(LineKind.meta, lines[3].kind);
    try std.testing.expectEqualStrings("\\ No newline at end of file", lines[3].text);
}

test "a blank line in a hunk is context and one after it is not a line" {
    const a = std.testing.allocator;
    const bytes =
        \\--- a/pad.txt
        \\+++ b/pad.txt
        \\@@ -1,3 +1,3 @@
        \\ one
        \\
        \\-three
        \\+3
        \\
        \\
    ;
    const files = (try parse(a, bytes)).?;
    defer deinit(files, a);

    // The blank line inside the hunk is the file's own empty line, whose one
    // leading space a fence strips. The blank line after the last declared
    // body line is the space between sections, and is not part of the hunk.
    const lines = files[0].hunks[0].lines;
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqual(LineKind.context, lines[1].kind);
    try std.testing.expectEqualStrings("", lines[1].text);
}

test "a file header is a diff and a bullet list is not" {
    const a = std.testing.allocator;
    const header =
        \\--- a/x.zig
        \\+++ b/x.zig
        \\@@ -1,1 +1,1 @@
        \\-a
        \\+b
        \\
    ;
    try std.testing.expect(looksLikeDiff(header));
    try std.testing.expect(looksLikeDiff("diff --git a/x b/x\nindex 1..2 100644\n"));

    // A bullet list is prose. Every one of these lines starts with the character
    // a diff marks a line with, and none of them is a line of a diff: it takes
    // the two file headers together, a `diff --git` line, or a hunk header to
    // say otherwise.
    try std.testing.expect(!looksLikeDiff("- item\n- another\n"));
    try std.testing.expect(!looksLikeDiff("+ item\n+ another\n"));
    try std.testing.expect(!looksLikeDiff("Steps:\n\n- a bullet\n+ not an added line\n"));

    // The pair still parses without a `diff --git` line above it.
    const files = (try parse(a, header)).?;
    defer deinit(files, a);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("b/x.zig", files[0].path);
    try std.testing.expectEqual(@as(usize, 1), files[0].hunks.len);

    // Bytes that open with a `---` and then say nothing else are not a diff,
    // which is an answer rather than a failure.
    try std.testing.expect((try parse(a, "- item\n--- a/x\n")) == null);
    try std.testing.expect((try parse(a, "an answer, at last\n")) == null);
}

test "an empty diff is an empty slice" {
    const a = std.testing.allocator;
    const files = (try parse(a, "")).?;
    defer deinit(files, a);
    try std.testing.expectEqual(@as(usize, 0), files.len);
    try std.testing.expect(!looksLikeDiff(""));
}

test "a file is named by its +++ line, or by its diff --git line" {
    const a = std.testing.allocator;
    // A plain `diff -u` header carries the file's timestamp after a tab, which
    // is not part of the name.
    const plain = (try parse(a, "--- a/x.zig\t2024-01-01 00:00:00\n+++ b/x.zig\t2024-01-01 00:00:00\n@@ -1,1 +1,1 @@\n-a\n+b\n")).?;
    defer deinit(plain, a);
    try std.testing.expectEqualStrings("b/x.zig", plain[0].path);

    // A binary diff has no `+++` line at all, and a section is still a section.
    const binary = (try parse(a, "diff --git a/logo.png b/logo.png\nindex abc..def 100644\nBinary files a/logo.png and b/logo.png differ\n")).?;
    defer deinit(binary, a);
    try std.testing.expectEqualStrings("b/logo.png", binary[0].path);
    try std.testing.expectEqual(@as(usize, 0), binary[0].hunks.len);

    // A deletion's `+++` names `/dev/null`, which is the format's way of saying
    // the file is gone rather than naming a file called that.
    const deleted = (try parse(a, "diff --git a/gone.zig b/gone.zig\ndeleted file mode 100644\n--- a/gone.zig\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-const gone = true;\n")).?;
    defer deinit(deleted, a);
    try std.testing.expectEqualStrings("b/gone.zig", deleted[0].path);

    // A hunk with no header above it is a fragment of a diff, and names no file.
    const fragment = (try parse(a, "@@ -10,1 +10,2 @@\n keep\n+add\n")).?;
    defer deinit(fragment, a);
    try std.testing.expectEqualStrings("", fragment[0].path);
    try std.testing.expectEqual(@as(usize, 1), fragment[0].hunks.len);
}

test "a malformed hunk header is an error rather than a panic" {
    const a = std.testing.allocator;
    // `@@` opens a hunk header and nothing else in a diff opens that way, so a
    // line that opens with it and is not one is a claim the bytes do not
    // support. The caller hears about it and draws the block as text.
    try std.testing.expectError(error.MalformedDiff, parse(a, "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +oops @@\n context\n"));
    // A count too large for the number it would be is refused where it is read,
    // so it can never become a size.
    try std.testing.expectError(error.MalformedDiff, parse(a, "--- a/x\n+++ b/x\n@@ -1,99999999999999999999999 +1,1 @@\n context\n"));
    try std.testing.expectError(error.MalformedDiff, parse(a, "--- a/x\n+++ b/x\n@@@ -1,3 +1,3 @@@\n context\n"));
}

test "the declared counts are read as numbers, never as sizes" {
    const a = std.testing.allocator;
    // A header claiming a hundred million lines of body allocates nothing for
    // them: the body is whatever follows, and the counts only say how much of
    // it the header expected.
    const files = (try parse(a, "--- a/x\n+++ b/x\n@@ -1,100000000 +1,100000000 @@\n-a\n+b\n")).?;
    defer deinit(files, a);
    try std.testing.expectEqual(@as(usize, 2), files[0].hunks[0].lines.len);
}

test "a diff past the bounds is a named error" {
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, max_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.DiffTooLarge, parse(a, oversized));

    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    for (0..max_files) |_| try many.appendSlice(a, "diff --git a/x b/x\n");
    const full = (try parse(a, many.items)).?;
    try std.testing.expectEqual(max_files, full.len);
    deinit(full, a);

    try many.appendSlice(a, "diff --git a/x b/x\n");
    try std.testing.expectError(error.TooManyFiles, parse(a, many.items));
}

test "an allocation that fails part way through leaves nothing behind" {
    const a = std.testing.allocator;
    const bytes =
        \\diff --git a/one.zig b/one.zig
        \\--- a/one.zig
        \\+++ b/one.zig
        \\@@ -1,2 +1,2 @@
        \\ keep
        \\-drop
        \\+add
        \\diff --git a/two.zig b/two.zig
        \\Binary files a/two.zig and b/two.zig differ
        \\
    ;
    // Every allocation the parse makes can be the one that gives up, and not
    // one of them may leak or be freed twice: the testing allocator is what
    // notices, and it keeps noticing until an index past the last allocation
    // lets the whole thing through.
    var allowed: usize = 0;
    while (true) : (allowed += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = allowed });
        const fa = failing.allocator();
        if (parse(fa, bytes)) |parsed| {
            const files = parsed orelse return error.NotADiff;
            deinit(files, fa);
            break;
        } else |err| if (err != error.OutOfMemory) return err;
    }
}

/// One side of a marked pair, read the way a drawer reads it: the text of
/// every span and whether it is marked. The caller writes out exactly the
/// spans it expects, so a merge that should have happened and did not is a
/// failure here rather than a line that draws with two marks side by side.
fn expectSpans(spans: []const Span, texts: []const []const u8, changed: []const bool) !void {
    try std.testing.expectEqual(texts.len, spans.len);
    for (spans, texts, changed) |span, text, marked| {
        try std.testing.expectEqualStrings(text, span.text);
        try std.testing.expectEqual(marked, span.changed);
    }
}

/// Everything one side's spans spell, which is the line they were read from
/// whenever they are a partition of it.
fn spanText(a: Allocator, spans: []const Span) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(a);
    for (spans) |span| try joined.appendSlice(a, span.text);
    return joined.toOwnedSlice(a);
}

test "a one-word change marks the word and not the rest" {
    const a = std.testing.allocator;
    const marked_pair = (try wordDiff(a, "const answer = 41;", "const answer = 42;")).?;
    defer freeWordDiff(marked_pair, a);

    // The numbers are the two words the other side does not carry, and they
    // are the whole of what is marked: the reader is shown the change, not two
    // lines to compare. A word reaches to the next whitespace, so the `;` is
    // part of the number it follows rather than a word of its own.
    try expectSpans(marked_pair.removed, &.{ "const answer = ", "41;" }, &.{ false, true });
    try expectSpans(marked_pair.added, &.{ "const answer = ", "42;" }, &.{ false, true });
}

test "identical lines are a pair with nothing marked" {
    const a = std.testing.allocator;
    const line = "    if (spans.len == 0) return null;";
    const marked_pair = (try wordDiff(a, line, line)).?;
    defer freeWordDiff(marked_pair, a);

    // One span for the whole line, because nothing in it is marked and runs
    // that agree about their mark are what a span is made of.
    try expectSpans(marked_pair.removed, &.{line}, &.{false});
    try expectSpans(marked_pair.added, &.{line}, &.{false});
}

test "the same words in another order are not a change" {
    const a = std.testing.allocator;
    const marked_pair = (try wordDiff(a, "alpha beta gamma", "gamma beta alpha")).?;
    defer freeWordDiff(marked_pair, a);

    // Marking is by whether the other line carries the word, and it carries
    // every one of them: a word that moved is not a word that changed, which
    // is the price of a split this dumb and the reason it is predictable.
    try expectSpans(marked_pair.removed, &.{"alpha beta gamma"}, &.{false});
    try expectSpans(marked_pair.added, &.{"gamma beta alpha"}, &.{false});
}

test "lines that share almost nothing are not a pair worth marking" {
    const a = std.testing.allocator;
    // Nothing in common at all, which is two lines that happen to stand next
    // to each other rather than one line that became another.
    try std.testing.expect((try wordDiff(a, "fn main() void {", "The quick brown fox")) == null);
    // One word in common out of three: marking it would paint most of both
    // sides, and a reader is not served by that.
    try std.testing.expect((try wordDiff(a, "foo bar baz", "foo qux quux")) == null);
    // Half of the longer side is where a pair stops being worth marking, and
    // one word of two is still on the side of a rewrite.
    const half = (try wordDiff(a, "alpha beta", "alpha gamma")) orelse return error.NotAPair;
    defer freeWordDiff(half, a);
}

test "a side with no words is not a pair" {
    const a = std.testing.allocator;
    // A line written from nothing or dropped to nothing is a whole-line
    // statement the diff has already made.
    try std.testing.expect((try wordDiff(a, "", "const x = 1;")) == null);
    try std.testing.expect((try wordDiff(a, "const x = 1;", "")) == null);
    // Whitespace is not a word, so a side made of it is as empty as one made
    // of nothing.
    try std.testing.expect((try wordDiff(a, "   \t ", "const x = 1;")) == null);
    try std.testing.expect((try wordDiff(a, "\r\n", "\r\n")) == null);
}

test "a pair that differs only in whitespace marks nothing" {
    const a = std.testing.allocator;
    // The words are the same words, so the indentation is left to the diff's
    // own columns rather than marked as a change to the line's text.
    const indent = (try wordDiff(a, "    x = 1;", "  x = 1;")).?;
    defer freeWordDiff(indent, a);
    try expectSpans(indent.removed, &.{"    x = 1;"}, &.{false});
    try expectSpans(indent.added, &.{"  x = 1;"}, &.{false});

    const spaced = (try wordDiff(a, "a  b", "a b")).?;
    defer freeWordDiff(spaced, a);
    try expectSpans(spaced.removed, &.{"a  b"}, &.{false});
    try expectSpans(spaced.added, &.{"a b"}, &.{false});

    // Whitespace inside a marked run stays with the word before it, so the
    // space after `keep` is drawn with `keep` and not with the word that
    // changed, and the indentation before the first word is never marked.
    const word = (try wordDiff(a, "  keep old;", "  keep new;")).?;
    defer freeWordDiff(word, a);
    try expectSpans(word.removed, &.{ "  keep ", "old;" }, &.{ false, true });
    try expectSpans(word.added, &.{ "  keep ", "new;" }, &.{ false, true });
}

test "arbitrary bytes are marked without a panic" {
    const a = std.testing.allocator;
    // Not text at all: a byte that never appears in UTF-8, a lone continuation
    // byte, a character cut in half and a NUL, on both sides of a pair.
    const pairs = [_][2][]const u8{
        .{ "\xff\xfe\x80", "\xff\xfe\x81" },
        .{ "a\x00b", "a\x00c" },
        .{ "\xc3(\xff", "\xc3)\xff" },
        .{ "\x7f\x80\x81", "\x7f\x80" },
        .{ "one\xff two", "one\xff three" },
    };
    for (pairs) |pair| {
        const marked_pair = (try wordDiff(a, pair[0], pair[1])) orelse continue;
        defer freeWordDiff(marked_pair, a);
        // Whatever the bytes are, each side's spans spell that side and none
        // of them is empty: a partition is the one thing a drawer relies on.
        const sides = [_][]const Span{ marked_pair.removed, marked_pair.added };
        for (pair, sides) |line, spans| {
            const joined = try spanText(a, spans);
            defer a.free(joined);
            try std.testing.expectEqualStrings(line, joined);
            for (spans) |span| try std.testing.expect(span.text.len > 0);
        }
    }

    // Bytes nobody here thought of, drawn from an alphabet of the ones that
    // are awkward: whitespace runs, a NUL, and bytes that are not UTF-8 at
    // all. Either the pair is not worth marking or it marks its own sides.
    var prng = std.Random.DefaultPrng.init(0x5ee5);
    const random = prng.random();
    const alphabet = "\x00\x09\x0a\x0d\x20ab\x7f\x80\xc3\xff";
    var removed: [64]u8 = undefined;
    var added: [64]u8 = undefined;
    for (0..512) |_| {
        for (&removed) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        for (&added) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        const marked_pair = (try wordDiff(a, &removed, &added)) orelse continue;
        defer freeWordDiff(marked_pair, a);
        const one = try spanText(a, marked_pair.removed);
        defer a.free(one);
        try std.testing.expectEqualStrings(&removed, one);
        const two = try spanText(a, marked_pair.added);
        defer a.free(two);
        try std.testing.expectEqualStrings(&added, two);
    }
}

test "a word diff that cannot allocate leaves nothing behind" {
    const a = std.testing.allocator;
    // The promise `parse` makes, made again over this call's shorter set of
    // allocations: a failing one may come at any point, and not one of them may
    // leak or be freed twice on the way out - the second side's spans in
    // particular, which are built while the first side's are already held.
    var allowed: usize = 0;
    while (true) : (allowed += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = allowed });
        const fa = failing.allocator();
        if (wordDiff(fa, "  const answer = 41;", "  const answer = 42;")) |marked| {
            if (marked) |pair| freeWordDiff(pair, fa);
            break;
        } else |err| if (err != error.OutOfMemory) return err;
    }
}

test "a word diff past the bounds is a named error" {
    const a = std.testing.allocator;

    // A side longer than any line of any diff this file reads.
    const huge = try a.alloc(u8, max_bytes + 1);
    defer a.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(error.DiffTooLarge, wordDiff(a, huge, "x"));

    // More words than one side is read for: a pair to draw as two whole lines
    // rather than to build a vocabulary for.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    for (0..max_words + 1) |_| try many.appendSlice(a, "word ");
    try std.testing.expectError(error.TooManyWords, wordDiff(a, many.items, "word word"));
}
