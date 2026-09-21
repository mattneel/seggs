//! The catalog of themes on disk: what a menu can list, and how one is loaded.
//!
//! The directory is the reader's as much as ours - the vendored Shiki
//! collection under `themes/catalog` is what ships, and anything the reader
//! drops into the same directory is listed with it - so the scan is written to
//! survive what it finds. A directory that is not there is an empty list rather
//! than an error, because a reader who deleted it wants an empty menu instead of
//! a menu that refuses to open. A file that is not a theme is left out with the
//! reason it was left out, and a file that lies about being one - a document
//! that opens like a theme and is not - is listed and fails when it is loaded,
//! with the parser's own error, which is where every other fault in a theme is
//! reported.
//!
//! The scan reads each candidate's *head* and nothing more. That is the whole
//! point: a menu wants 65 names, and reading the 1.8 MB behind them to draw a
//! list is a cost nobody notices until the disk is slow. It is also why a row is
//! labelled from its file name rather than from the `displayName` the document
//! carries: in the vendored collection that key sits between 1.2 kB and 27 kB
//! into the file, behind the whole `colors` map, so reading it would mean
//! reading the catalog. The head is read for a different question - does this
//! file open like a document this editor can read - and a file that does not is
//! skipped by name and reason.
//!
//! Ownership is stated once: the catalog owns every path, label, and name it
//! returns and `deinit` gives them back, while a theme from `load` is entirely
//! the caller's and `theme.deinit` releases it. The module holds no copy, no
//! cache, and no state between calls, so a preview that loads a theme for every
//! row it passes over owns exactly the one it is showing.
const std = @import("std");
const theme = @import("theme.zig");
const theme_tm = @import("../services/theme_tm.zig");
const theme_vscode = @import("../services/theme_vscode.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// How many files the scan will look at, and so how many rows it can return.
/// The vendored collection is 65 files; the bound is four times that, so a
/// reader who adds their own themes never meets it, and a directory that has
/// become something else - a checkout, a downloads folder - is not walked to the
/// end.
pub const max_entries: usize = 256;

/// How much of a file is read to decide whether it is a theme document at all.
/// A document opens with `{` or `<`; the rest of the head is slack for a byte
/// order mark and for a file that opens with an unusually long first key.
pub const head_bytes: usize = 256;

/// The suffixes a theme file goes by. `.json` is what this editor and VS Code
/// write and what the whole vendored collection is; `.tmTheme` is the TextMate
/// plist, which `services/theme_tm.zig` reads and which a reader is likely to
/// have. A file named neither way is not a candidate and is not reported: a
/// directory of themes may hold a README without the editor claiming that it
/// skipped it.
const suffixes = [_][]const u8{ ".json", ".tmTheme" };

/// One theme file the catalog found.
pub const Entry = struct {
    /// Where the file is, owned by the catalog.
    path: []u8,
    /// The row a menu shows for it, owned by the catalog.
    label: []u8,

    /// The name the file goes by: its base name without the suffix. That is
    /// what a theme document states about itself, and in every file of the
    /// vendored collection it is the same word.
    pub fn slug(self: Entry) []const u8 {
        return std.fs.path.stem(std.fs.path.basename(self.path));
    }
};

/// Why a file that looked like a theme was left out of the list.
pub const Reason = enum {
    /// Not a file: a directory, a device, a FIFO, or anything else a reader
    /// would block on or fail to read.
    not_a_file,
    /// Larger than the largest document the theme readers accept, so it can
    /// never be loaded as one.
    too_large,
    /// It does not open like a document this editor reads: not a JSON object
    /// and not an XML plist.
    not_a_document,
    /// It could not be read at all.
    unreadable,

    /// The words to say it in, for a status line or a row's detail.
    pub fn text(self: Reason) []const u8 {
        return switch (self) {
            .not_a_file => "not a file",
            .too_large => "too large to be a theme",
            .not_a_document => "not a theme document",
            .unreadable => "unreadable",
        };
    }
};

/// A candidate that was left out, and why. A name and not a path: the directory
/// is the catalog's own, and a reason is what a reader needs to fix it.
pub const Skip = struct {
    /// The file's name, owned by the catalog.
    name: []u8,
    reason: Reason,
};

/// What is in one directory of themes.
pub const Catalog = struct {
    allocator: Allocator,
    /// The directory the list was built from, owned.
    dir: []u8,
    /// The theme files it holds, in file-name order, owned.
    entries: []Entry,
    /// The candidates it left out, in file-name order, owned.
    skipped: []Skip,
    /// How many candidates were past the bound and so were never looked at. A
    /// count rather than a row each: a list that reports ten thousand files it
    /// did not examine is not saying anything a reader can use.
    dropped: usize,

    /// List a directory. Every candidate is named by its file name, and a
    /// candidate is a file whose name ends in a suffix a theme goes by; the rest
    /// of what a directory holds is not walked and not reported.
    ///
    /// A directory that cannot be opened is an empty catalog rather than an
    /// error - the menu opens on nothing - but a directory that fails while it
    /// is being read is an error, because a list that is missing rows without
    /// saying so is worse than one that says it could not be built.
    pub fn scan(a: Allocator, io: Io, dir_path: []const u8) !Catalog {
        var catalog: Catalog = .{
            .allocator = a,
            .dir = try a.dupe(u8, dir_path),
            .entries = &.{},
            .skipped = &.{},
            .dropped = 0,
        };
        errdefer a.free(catalog.dir);

        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        errdefer freeEntries(a, entries.items);
        var skipped: std.ArrayListUnmanaged(Skip) = .empty;
        errdefer freeSkips(a, skipped.items);

        var directory = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return catalog;
        defer directory.close(io);

        var iterator = directory.iterate();
        while (try iterator.next(io)) |candidate| {
            if (!isCandidate(candidate.name)) continue;
            // Every candidate looked at becomes either a row or a reason, so
            // the two together are how much work the scan has done.
            if (entries.items.len + skipped.items.len >= max_entries) {
                catalog.dropped += 1;
                continue;
            }
            switch (try judge(a, io, directory, dir_path, candidate.name)) {
                .entry => |entry| try entries.append(a, entry),
                .skip => |reason| {
                    const name = try a.dupe(u8, candidate.name);
                    errdefer a.free(name);
                    try skipped.append(a, .{ .name = name, .reason = reason });
                },
            }
        }

        // A directory is read in whatever order the file system keeps it, and a
        // list that reordered itself between two openings would be a list a
        // reader cannot learn.
        std.mem.sort(Entry, entries.items, {}, lessEntry);
        std.mem.sort(Skip, skipped.items, {}, lessSkip);
        catalog.entries = try entries.toOwnedSlice(a);
        catalog.skipped = try skipped.toOwnedSlice(a);
        return catalog;
    }

    /// Give back everything the catalog owns.
    pub fn deinit(self: *Catalog) void {
        freeEntries(self.allocator, self.entries);
        freeSkips(self.allocator, self.skipped);
        self.allocator.free(self.dir);
        self.* = undefined;
    }

    /// The row showing the theme that calls itself `slug`, or null when the
    /// catalog does not hold it. Matched on the file's base name without its
    /// suffix, case-insensitively, which is the name a row is labelled from and
    /// the name a theme document states. A reader asking where the theme they
    /// are looking at sits in the list asks this.
    pub fn index(self: Catalog, slug: []const u8) ?usize {
        for (self.entries, 0..) |entry, position| {
            if (std.ascii.eqlIgnoreCase(entry.slug(), slug)) return position;
        }
        return null;
    }
};

/// What one candidate is: a row, or the reason it is not one.
const Verdict = union(enum) {
    entry: Entry,
    skip: Reason,
};

/// Whether a file is worth looking at: a theme file is named like one. The
/// check is on the name, so it costs nothing and takes no stat.
fn isCandidate(name: []const u8) bool {
    for (suffixes) |suffix| {
        if (std.ascii.endsWithIgnoreCase(name, suffix)) return true;
    }
    return false;
}

/// Decide what one candidate is, reading its head and nothing else.
fn judge(a: Allocator, io: Io, directory: Io.Dir, dir_path: []const u8, name: []const u8) !Verdict {
    // Statting before opening is what keeps a directory, a device, or a FIFO
    // from being opened to find out what it is: a read on a FIFO that nobody
    // writes to would block the editor forever.
    const stat = directory.statFile(io, name, .{}) catch return .{ .skip = .unreadable };
    if (stat.kind != .file) return .{ .skip = .not_a_file };
    if (stat.size > theme.max_document_bytes) return .{ .skip = .too_large };

    var file = directory.openFile(io, name, .{}) catch return .{ .skip = .unreadable };
    defer file.close(io);
    var head: [head_bytes]u8 = undefined;
    const read = file.readPositionalAll(io, &head, 0) catch return .{ .skip = .unreadable };
    if (!opensLikeDocument(head[0..read])) return .{ .skip = .not_a_document };

    const path = try std.fs.path.join(a, &.{ dir_path, name });
    errdefer a.free(path);
    return .{ .entry = .{ .path = path, .label = try labelFor(a, name) } };
}

/// Whether a document opens like one this editor reads: a JSON object, or an
/// XML plist, after an optional byte order mark and spaces.
///
/// The check is a courtesy to the list and not a parse, so it can only be too
/// generous: a file that opens like a document and is not one is listed, and the
/// reader is what refuses it by name when it is loaded. What it catches is the
/// other kind of file entirely - an empty file, a README named `.json`, a
/// download that arrived as something else - which no reader could ever make a
/// theme of and no list should offer.
fn opensLikeDocument(head: []const u8) bool {
    var body = head;
    if (std.mem.startsWith(u8, body, "\xef\xbb\xbf")) body = body[3..];
    body = std.mem.trimStart(u8, body, " \t\r\n");
    if (body.len == 0) return false;
    return body[0] == '{' or body[0] == '<';
}

/// The row a menu shows for a file: its name without the suffix, words split on
/// `-`, `_`, `.` and space and written with a space between them, and the first
/// letter of each word upper-cased - `github-dark-default.json` is
/// `Github Dark Default`.
///
/// It comes from the file name and not from the document because the document
/// would have to be read to be asked: the `displayName` a theme states about
/// itself sits behind the whole `colors` map, and reading it for 65 rows is the
/// cost this scan exists to avoid. The name the file goes by is the name the
/// vendored collection uses for itself, and it is the name a reader sees in the
/// directory they dropped the file into. In 15 of those 65 files the derived row
/// is not the `displayName` word for word, and the difference is always a
/// diacritic (`Catppuccin Frappé`), an acronym's capitals (`GitHub`), or a word
/// the file adds to itself (`Dracula Theme`) - never a label that reads as a
/// different theme.
fn labelFor(a: Allocator, name: []const u8) ![]u8 {
    const stem = std.fs.path.stem(name);
    const label = try a.dupe(u8, stem);
    errdefer a.free(label);
    var first = true;
    for (label) |*character| {
        if (character.* == '-' or character.* == '_' or character.* == '.' or character.* == ' ') {
            character.* = ' ';
            first = true;
        } else if (first and std.ascii.isAlphabetic(character.*)) {
            character.* = std.ascii.toUpper(character.*);
            first = false;
        } else {
            first = false;
        }
    }
    return label;
}

fn lessEntry(_: void, left: Entry, right: Entry) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

fn lessSkip(_: void, left: Skip, right: Skip) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn freeEntries(a: Allocator, entries: []Entry) void {
    for (entries) |entry| {
        a.free(entry.path);
        a.free(entry.label);
    }
    if (entries.len > 0) a.free(entries);
}

fn freeSkips(a: Allocator, skips: []Skip) void {
    for (skips) |skip| a.free(skip.name);
    if (skips.len > 0) a.free(skips);
}

/// The largest document `load` will read: one byte above the readers' own
/// bound, because a stream that reaches the limit it was given is reported as
/// too long, while a document of exactly `theme.max_document_bytes` is one the
/// readers accept.
const read_limit = theme.max_document_bytes + 1;

/// Read one theme file and parse it, deciding the format from the document the
/// way `parse` does. The path is the caller's, so a catalog entry and a theme
/// kept anywhere else are loaded by the same call.
///
/// The theme that comes back is entirely the caller's - it owns its name and
/// every selector and `theme.deinit` gives them back - and a load that fails
/// leaves nothing behind for the caller to free.
///
/// Nothing is cached, and the arithmetic is why. Loading every file of the
/// vendored collection through this function - read and parse both - takes
/// about 160 ms in a Debug build: 2.5 ms for the average theme, 4.7 ms for the
/// slowest of the 65, against a frame of 16.7 ms. A preview loads only when the
/// row it is showing changes, which a key press or a pointer move does at most
/// once, so the work is a quarter of a frame at the moment the reader looks at a
/// different theme and nothing at all when they do not. A cache would have to
/// hand back a copy, because a theme owns its selectors and a borrowed one would
/// be a theme the next load could free, and it would have to notice a reader
/// editing a file in a directory that is theirs: more machinery than a few
/// milliseconds are worth.
pub fn load(a: Allocator, io: Io, path: []const u8) !theme.Theme {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(read_limit)) catch |err| switch (err) {
        error.StreamTooLong => return error.ThemeTooLarge,
        else => |other| return other,
    };
    defer a.free(bytes);
    return parse(a, bytes);
}

/// Parse a theme document into the native theme the renderer draws with.
///
/// The format is decided by the document rather than by the file's name,
/// because one that has been renamed is still a theme, and this is the same rule
/// `App.loadTheme` applies so a theme behaves the same wherever it is loaded
/// from: an XML plist is a TextMate theme, a JSON document that names token
/// colours is a VS Code one, and anything else is this editor's own format.
/// Published because a caller that already has the bytes - the editor's own
/// loader reads through the platform file path - should not have to decide the
/// question a second time.
///
/// The returned theme owns its name and selectors; `theme.deinit` releases them.
pub fn parse(a: Allocator, bytes: []const u8) !theme.Theme {
    var start: usize = 0;
    while (start < bytes.len and switch (bytes[start]) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    }) : (start += 1) {}
    const trimmed = bytes[start..];
    if (trimmed.len > 0 and trimmed[0] == '<') return theme_tm.parse(a, bytes);
    if (std.mem.indexOf(u8, bytes, "tokenColors") != null) return theme_vscode.parse(a, bytes);
    return theme.parse(a, bytes);
}

const testing = std.testing;

/// A directory the test can name. The catalog takes a path rather than a handle
/// - a caller hands it the directory the editor already resolves everything else
/// against - so the path is rebuilt here from the pieces `std.testing.tmpDir`
/// made the directory out of.
fn scratchDirectory(a: Allocator, tmp: *testing.TmpDir) ![]u8 {
    return std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

/// The vendored collection, found the way the importer fixtures are: the test
/// binary runs from wherever the build was started - the repository root for
/// `zig build test`, a directory under it when a checkout is built from one - so
/// the directory is looked for on the way up rather than assumed in one place.
/// A collection that is missing fails the test: one that was silently skipped
/// would prove nothing.
fn vendoredCatalog(a: Allocator) ![]u8 {
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        var path: std.ArrayListUnmanaged(u8) = .empty;
        errdefer path.deinit(a);
        for (0..depth) |_| try path.appendSlice(a, "../");
        try path.appendSlice(a, "themes/catalog");
        if (Io.Dir.cwd().openDir(testing.io, path.items, .{})) |found| {
            found.close(testing.io);
            return path.toOwnedSlice(a);
        } else |_| {
            path.deinit(a);
        }
    }
    return error.ThemesCatalogMissing;
}

test "the list holds the theme files and names what it left out" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try scratchDirectory(a, &tmp);
    defer a.free(dir);

    try tmp.dir.writeFile(io, .{
        .sub_path = "alpha.json",
        .data = "{ \"name\": \"alpha\", \"chrome\": { \"background\": \"#112233\" } }",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "beta.tmTheme",
        .data = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "not a theme file, and not a candidate" });
    // A candidate that is not a document at all: skipped, with the reason. A
    // document that opens like a theme and is not one is the next test's
    // business, because only the reader can tell.
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.json", .data = "a README that was saved as a theme, prose and all" });
    var nested = try tmp.dir.createDirPathOpen(io, "nested.json", .{});
    nested.close(io);
    const oversized = try a.alloc(u8, theme.max_document_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try tmp.dir.writeFile(io, .{ .sub_path = "huge.json", .data = oversized });

    var catalog = try Catalog.scan(a, io, dir);
    defer catalog.deinit();

    try testing.expectEqual(@as(usize, 2), catalog.entries.len);
    try testing.expectEqualStrings("alpha.json", std.fs.path.basename(catalog.entries[0].path));
    try testing.expectEqualStrings("Alpha", catalog.entries[0].label);
    try testing.expectEqualStrings("alpha", catalog.entries[0].slug());
    try testing.expectEqualStrings("beta.tmTheme", std.fs.path.basename(catalog.entries[1].path));
    try testing.expectEqualStrings("Beta", catalog.entries[1].label);

    try testing.expectEqual(@as(usize, 3), catalog.skipped.len);
    try testing.expectEqualStrings("broken.json", catalog.skipped[0].name);
    try testing.expectEqual(Reason.not_a_document, catalog.skipped[0].reason);
    try testing.expectEqualStrings("huge.json", catalog.skipped[1].name);
    try testing.expectEqual(Reason.too_large, catalog.skipped[1].reason);
    try testing.expectEqualStrings("nested.json", catalog.skipped[2].name);
    try testing.expectEqual(Reason.not_a_file, catalog.skipped[2].reason);
    try testing.expectEqual(@as(usize, 0), catalog.dropped);

    // The prose file was never a candidate, so it is neither a row nor a reason.
    try testing.expectEqual(@as(usize, 0), catalog.index("alpha").?);
    try testing.expectEqual(@as(usize, 1), catalog.index("BETA").?);
    try testing.expect(catalog.index("gamma") == null);
}

test "a directory that is not there is an empty list, not an error" {
    const a = testing.allocator;
    const io = testing.io;
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", "seggs-theme-catalog-absent" });
    defer a.free(dir);
    // Whatever an earlier run left behind goes, so the test is about a directory
    // that is really not there.
    Io.Dir.cwd().deleteTree(io, dir) catch {};

    var catalog = try Catalog.scan(a, io, dir);
    defer catalog.deinit();

    try testing.expectEqual(@as(usize, 0), catalog.entries.len);
    try testing.expectEqual(@as(usize, 0), catalog.skipped.len);
    try testing.expectEqual(@as(usize, 0), catalog.dropped);
    try testing.expectEqualStrings(dir, catalog.dir);
}

test "a label is derived from the file name" {
    const a = testing.allocator;
    const cases = [_]struct { file: []const u8, label: []const u8 }{
        .{ .file = "github-dark-default.json", .label = "Github Dark Default" },
        .{ .file = "synthwave-84.json", .label = "Synthwave 84" },
        .{ .file = "nord.json", .label = "Nord" },
        .{ .file = "one_dark.pro.tmTheme", .label = "One Dark Pro" },
        .{ .file = "Catppuccin-Mocha.JSON", .label = "Catppuccin Mocha" },
    };
    for (cases) |case| {
        const label = try labelFor(a, case.file);
        defer a.free(label);
        try testing.expectEqualStrings(case.label, label);
    }
}

test "a theme loads, and one that only opens like a theme says why it does not" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try scratchDirectory(a, &tmp);
    defer a.free(dir);

    try tmp.dir.writeFile(io, .{
        .sub_path = "probe.json",
        .data =
        \\{ "name": "probe",
        \\  "colors": { "editor.background": "#101418" },
        \\  "tokenColors": [ { "scope": "keyword", "settings": { "foreground": "#f38ba8" } } ] }
        ,
    });
    // A file that opens like a document and is not one: the scan lists it, and
    // the reader is what refuses it, by name, when it is loaded.
    try tmp.dir.writeFile(io, .{ .sub_path = "torn.json", .data = "{ \"name\": \"torn\", " });

    var catalog = try Catalog.scan(a, io, dir);
    defer catalog.deinit();
    try testing.expectEqual(@as(usize, 2), catalog.entries.len);

    const loaded = try load(a, io, catalog.entries[0].path);
    defer theme.deinit(loaded, a);
    try testing.expectEqualStrings("probe", loaded.name);
    try testing.expect(!std.mem.eql(
        u8,
        std.mem.asBytes(&loaded.chrome.background),
        std.mem.asBytes(&theme.defaults().chrome.background),
    ));
    try testing.expect(theme.styleFor(loaded, "keyword.control").fg != null);

    // A failed load leaves nothing behind: the test allocator fails this test if
    // a document it refused was still holding memory.
    try testing.expectError(error.MalformedJson, load(a, io, catalog.entries[1].path));

    const absent = try std.fs.path.join(a, &.{ dir, "absent.json" });
    defer a.free(absent);
    try testing.expectError(error.FileNotFound, load(a, io, absent));
}

test "the scan is bounded and counts the files it did not look at" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try scratchDirectory(a, &tmp);
    defer a.free(dir);

    var name_buffer: [64]u8 = undefined;
    for (0..max_entries + 4) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "theme-{d:0>3}.json", .{index});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }

    var catalog = try Catalog.scan(a, io, dir);
    defer catalog.deinit();

    try testing.expectEqual(@as(usize, 0), catalog.entries.len);
    try testing.expectEqual(max_entries, catalog.skipped.len);
    try testing.expectEqual(@as(usize, 4), catalog.dropped);
    // Every candidate is looked at in the only way an empty file can be: as a
    // file that is not a theme document.
    try testing.expectEqual(Reason.not_a_document, catalog.skipped[0].reason);
}

test "the vendored catalog is listed whole and skips nothing" {
    const a = testing.allocator;
    const dir = try vendoredCatalog(a);
    defer a.free(dir);

    var catalog = try Catalog.scan(a, testing.io, dir);
    defer catalog.deinit();

    // The commit this collection was vendored from holds 65 theme files; a
    // re-vendoring updates this number with the files, and the number is here so
    // that a collection which lost one to a bad download is not shipped quietly.
    try testing.expectEqual(@as(usize, 65), catalog.entries.len);
    try testing.expectEqual(@as(usize, 0), catalog.dropped);
    // Nothing in the collection is a file the scan refuses: every one of them
    // opens like a theme document.
    for (catalog.skipped) |skip| {
        std.debug.print("skipped {s}: {s}\n", .{ skip.name, skip.reason.text() });
    }
    try testing.expectEqual(@as(usize, 0), catalog.skipped.len);
}

test "a theme in the vendored catalog loads through the module" {
    const a = testing.allocator;
    const dir = try vendoredCatalog(a);
    defer a.free(dir);

    var catalog = try Catalog.scan(a, testing.io, dir);
    defer catalog.deinit();

    // The premise of the whole collection: the scan finds a file, the load reads
    // and parses it, and what comes back is a theme that paints something. A
    // file that imports to nothing - the default background, no rules - would be
    // a row in the menu that changes nothing when it is chosen.
    const entry = catalog.entries[catalog.index("min-dark").?];
    const loaded = try load(a, testing.io, entry.path);
    defer theme.deinit(loaded, a);

    try testing.expectEqualStrings("min-dark", loaded.name);
    try testing.expect(!std.mem.eql(
        u8,
        std.mem.asBytes(&loaded.chrome.background),
        std.mem.asBytes(&theme.defaults().chrome.background),
    ));
    // A rule from the file reaches a scope the editor's own scanner produces,
    // which is what colouring a document with this theme does.
    try testing.expect(theme.styleFor(loaded, "comment.line").fg != null);
}

test "every theme in the vendored catalog imports" {
    const a = testing.allocator;
    const dir = try vendoredCatalog(a);
    defer a.free(dir);

    var catalog = try Catalog.scan(a, testing.io, dir);
    defer catalog.deinit();

    // Every file of the collection, not a sample: a theme file is a document
    // written by someone else about a format this editor only partly
    // implements, and the collection is the fixture that says where the gaps
    // are. Five of the sixty-five failed to import until the reader learned the
    // four-digit `#rgba` spelling and that a rule may say "inherit" - this test
    // is where the next spelling to go missing will be seen, rather than in a row
    // of the picker that refuses to preview.
    for (catalog.entries) |entry| {
        const loaded = load(a, testing.io, entry.path) catch |err| {
            std.debug.print("{s} does not import: {s}\n", .{ entry.path, @errorName(err) });
            return err;
        };
        defer theme.deinit(loaded, a);
        // A document that names itself names itself with the word its file goes
        // by: that is how `Catalog.index` finds the row a loaded theme is on.
        try testing.expectEqualStrings(entry.slug(), loaded.name);
        // And it carries rules, or choosing it would change nothing.
        try testing.expect(loaded.syntax.len > 0);
    }
}
