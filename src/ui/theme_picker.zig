//! The theme switcher's own state: the rows it offers, the row that is
//! showing, and what a reader's answers mean.
//!
//! The catalog is a directory and a list is a widget; this is the part between
//! them that has rules, and the rules are about previewing. A preview is not a
//! choice: the row the reader passes over puts its theme on screen at once, and
//! the theme they came from has to stay alive until they say whether they meant
//! it. So this module remembers which row is showing and hands the caller the
//! file to load rather than loading it: a document is loaded by whoever applies
//! it, and that is the editor, which is the one thing that has to keep two
//! themes alive at once - the one that was committed and the one a preview is
//! showing.
//!
//! Nothing here is retried by accident. A row whose file will not load is
//! remembered as refused, with the reason, so a pointer resting on it does not
//! read the file once a frame; asking about a different row forgets the refusal,
//! so coming back to it tries again, because a reader who has just fixed the file
//! expects the list to notice.
const std = @import("std");
const menu = @import("menu.zig");
const theme_catalog = @import("theme_catalog.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// What it takes to show the theme a row holds.
pub const Step = union(enum) {
    /// Read this file and put it on screen.
    load: []const u8,
    /// Nothing to do: this row's theme is the one already on screen.
    keep,
    /// This row's file would not load, and this is why.
    refused: Refusal,
};

/// A row that would not load. Kept rather than reported once so that the reader
/// who leaves the highlight there is told what happened exactly once, and
/// forgotten as soon as they ask about another row.
pub const Refusal = struct {
    /// The row whose file refused to load.
    row: usize,
    /// The reader's own error, as the reader named it: `MalformedJson`,
    /// `InvalidColor`, `FileNotFound`. The words are the importer's, because
    /// they are what a person fixes.
    reason: anyerror,
};

pub const Picker = struct {
    allocator: Allocator,
    /// The themes on disk, owned here.
    catalog: theme_catalog.Catalog,
    /// The rows the list draws, in catalog order: one per theme file, labelled
    /// the way the catalog names it. Owned here; the labels are the catalog's.
    items: []menu.Item,
    /// The row whose theme was on screen when the picker opened, when the
    /// catalog holds it. The list opens there, so an untouched list says which
    /// theme the reader is looking at rather than offering them an arbitrary one.
    origin: ?usize,
    /// The row whose theme is on screen because of this picker, when a row is.
    /// Null until a preview happens, which is what keeps the theme that was
    /// already up from being read again for nothing.
    showing: ?usize = null,
    /// The last row whose file would not load.
    refused: ?Refusal = null,

    /// Open the list over a directory of themes, with the theme the editor is
    /// already showing named so the highlight can start there. The name is the
    /// one a theme file states about itself, which is the name its row goes by.
    pub fn open(a: Allocator, io: Io, dir: []const u8, current: []const u8) !Picker {
        var catalog = try theme_catalog.Catalog.scan(a, io, dir);
        errdefer catalog.deinit();
        const items = try a.alloc(menu.Item, catalog.entries.len);
        errdefer a.free(items);
        for (catalog.entries, items, 0..) |entry, *item, index| {
            item.* = .{ .label = entry.label, .key = index };
        }
        return .{
            .allocator = a,
            .catalog = catalog,
            .items = items,
            .origin = catalog.index(current),
        };
    }

    pub fn deinit(self: *Picker) void {
        self.allocator.free(self.items);
        self.catalog.deinit();
        self.* = undefined;
    }

    /// The rows to hand the list widget.
    pub fn rows(self: *const Picker) []const menu.Item {
        return self.items;
    }

    /// The row the highlight starts on: the theme already on screen when the
    /// catalog holds it, and the first row when it does not - a theme loaded
    /// from somewhere else has no row here to point at.
    pub fn opening(self: *const Picker) usize {
        return self.origin orelse 0;
    }

    /// What the highlight landing on `row` means. Called whenever the row may
    /// have changed - a key, a pointer - and answers the same way every time for
    /// the same row, so a caller that asks twice does not load twice.
    pub fn preview(self: *Picker, row: usize) Step {
        if (self.refused) |refusal| {
            if (refusal.row == row) return .{ .refused = refusal };
            // A different row is a fresh question, so the answer to the old one
            // is dropped: coming back to it reads the file again.
            self.refused = null;
        }
        if (self.showing) |showing| {
            if (showing == row) return .keep;
        } else if (self.origin) |origin| {
            // Nothing has been previewed, so the theme on screen is this row's
            // own and there is nothing to read.
            if (origin == row) return .keep;
        }
        const row_entry = self.entryAt(row) orelse return .keep;
        return .{ .load = row_entry.path };
    }

    /// Say that a row's theme is now the one on screen.
    pub fn shown(self: *Picker, row: usize) void {
        self.showing = row;
    }

    /// Say that a row's file would not load. The row stays where it was, if one
    /// was showing: a failed read leaves the last good theme on screen, and the
    /// picker has to agree with what the reader can see.
    pub fn refusedAt(self: *Picker, row: usize, reason: anyerror) void {
        self.refused = .{ .row = row, .reason = reason };
    }

    /// The words to name a row by, for a status line. Empty when the row is not
    /// one the catalog holds.
    pub fn label(self: *const Picker, row: usize) []const u8 {
        if (row >= self.items.len) return "";
        return self.items[row].label;
    }

    fn entryAt(self: *const Picker, row: usize) ?theme_catalog.Entry {
        if (row >= self.catalog.entries.len) return null;
        return self.catalog.entries[row];
    }
};

const testing = std.testing;

/// Whether a step asks for nothing to be loaded, which is the answer both for
/// the row that is already on screen and for a row the list does not have.
fn expectKeep(step: Step) !void {
    switch (step) {
        .keep => {},
        else => return error.TestUnexpectedResult,
    }
}

/// Whether a step asks for the named file to be loaded, named by its base name
/// so a test does not have to know the directory it made.
fn expectLoad(step: Step, file: []const u8) !void {
    switch (step) {
        .load => |path| try testing.expectEqualStrings(file, std.fs.path.basename(path)),
        else => return error.TestUnexpectedResult,
    }
}

/// Whether a step reports the named row as refused, for the named reason.
fn expectRefused(step: Step, row: usize, reason: anyerror) !void {
    switch (step) {
        .refused => |refusal| {
            try testing.expectEqual(row, refusal.row);
            try testing.expectEqual(reason, refusal.reason);
        },
        else => return error.TestUnexpectedResult,
    }
}

/// A directory a test can name. The picker takes a path rather than a handle -
/// the editor hands it the directory it resolves everything else against - so
/// the path is rebuilt here from the pieces `std.testing.tmpDir` made the
/// directory out of.
fn scratchDirectory(a: Allocator, tmp: *testing.TmpDir) ![]u8 {
    return std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

/// Fill a directory with themes that name themselves the way their files do,
/// which is what the vendored collection does and what the list is read by.
fn writeThemes(a: Allocator, tmp: *testing.TmpDir) ![]u8 {
    const io = testing.io;
    for ([_][]const u8{ "alpha", "beta", "gamma" }) |name| {
        const file = try std.fmt.allocPrint(a, "{s}.json", .{name});
        defer a.free(file);
        const document = try std.fmt.allocPrint(a, "{{ \"name\": \"{s}\", \"chrome\": {{ \"background\": \"#123456\" }} }}", .{name});
        defer a.free(document);
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = document });
    }
    return scratchDirectory(a, tmp);
}

test "the list opens on the theme on screen, and that row needs no read" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try writeThemes(a, &tmp);
    defer a.free(dir);

    var picker = try Picker.open(a, testing.io, dir, "beta");
    defer picker.deinit();

    try testing.expectEqual(@as(usize, 3), picker.rows().len);
    try testing.expectEqualStrings("Alpha", picker.rows()[0].label);
    try testing.expectEqual(@as(usize, 1), picker.opening());

    // The row the editor is already showing is not read again: the theme on
    // screen is that row's theme, and loading it would be work with no reader
    // behind it.
    try expectKeep(picker.preview(picker.opening()));

    // Another row is a file to load, named by its path.
    try expectLoad(picker.preview(2), "gamma.json");
    // And the row is named the way the list draws it: from the file name, which
    // is what a menu can have without reading the themes behind it.
    try testing.expectEqualStrings("Gamma", picker.label(2));
}

test "the row that is showing is remembered, so the highlight reads a file once" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try writeThemes(a, &tmp);
    defer a.free(dir);

    var picker = try Picker.open(a, testing.io, dir, "beta");
    defer picker.deinit();

    // Moving onto Alpha loads it, and asking again about the same row does not:
    // a pointer that jitters over one row reads one file.
    try expectLoad(picker.preview(0), "alpha.json");
    picker.shown(0);
    try expectKeep(picker.preview(0));

    // Moving back to the row the reader started on has to load it again, because
    // what is on screen is now Alpha's theme rather than Beta's.
    try expectLoad(picker.preview(picker.opening()), "beta.json");
    picker.shown(picker.opening());
    try expectKeep(picker.preview(picker.opening()));
}

test "a row that will not load is refused, and asked again when the reader comes back" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try writeThemes(a, &tmp);
    defer a.free(dir);

    var picker = try Picker.open(a, testing.io, dir, "beta");
    defer picker.deinit();

    picker.refusedAt(2, error.MalformedJson);
    try expectRefused(picker.preview(2), 2, error.MalformedJson);
    // The same row asked about again is the same answer: the file is not read
    // once a frame by a pointer resting on it.
    try expectRefused(picker.preview(2), 2, error.MalformedJson);

    // A different row is a fresh question, and the row that was refused is
    // tried again when the reader comes back to it - they may have fixed it.
    try expectKeep(picker.preview(picker.opening()));
    try expectLoad(picker.preview(2), "gamma.json");
}

test "a directory that is not there is a list with no rows" {
    const a = testing.allocator;
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", "seggs-theme-picker-absent" });
    defer a.free(dir);
    Io.Dir.cwd().deleteTree(testing.io, dir) catch {};

    var picker = try Picker.open(a, testing.io, dir, "seggs");
    defer picker.deinit();

    try testing.expectEqual(@as(usize, 0), picker.rows().len);
    try testing.expectEqual(@as(usize, 0), picker.opening());
    // A row the list does not have is nothing to show rather than a fault: the
    // caller is a list widget, and an empty list is a list.
    try expectKeep(picker.preview(0));
    try testing.expectEqualStrings("", picker.label(0));
}
