const std = @import("std");
const text = @import("text.zig");
const Allocator = std.mem.Allocator;

/// IME composition state. Committed text never flows through here: it arrives
/// as a separate text-input event once the composition ends, so this only
/// tracks the in-progress string and the selection inside it.
pub const Preedit = struct {
    text: std.ArrayList(u8) = .empty,
    /// Selection start inside the composition, in bytes. 0 means unset.
    start: usize = 0,
    /// Selection length inside the composition, in bytes. 0 means unset.
    length: usize = 0,

    /// Compositions longer than this are dropped. No real IME produces them,
    /// and the composition is drawn inline, so it must stay bounded.
    pub const max_bytes = 1024;

    pub fn deinit(self: *Preedit, a: Allocator) void {
        self.text.deinit(a);
    }

    /// Replace the composition. Empty or oversized text ends it, which is how
    /// a cancelled composition is reported.
    pub fn update(self: *Preedit, a: Allocator, bytes: []const u8, start: i32, length: i32) !void {
        self.clear();
        if (bytes.len == 0 or bytes.len > max_bytes) return;
        try self.text.appendSlice(a, bytes);
        if (start > 0) self.start = @intCast(start);
        if (length > 0) self.length = @intCast(length);
    }

    pub fn clear(self: *Preedit) void {
        self.text.clearRetainingCapacity();
        self.start = 0;
        self.length = 0;
    }

    /// Number of glyph cells the composition occupies when drawn inline.
    pub fn cellCount(self: *const Preedit) usize {
        return cellsIn(self.text.items);
    }

    /// Cell offset and width of the segment the input method reports as
    /// selected. SDL reports the region in bytes of the composition, which can
    /// lag the text carried by the same event, so it is clamped to the
    /// composition and snapped back to a grapheme boundary.
    pub fn selectionCells(self: *const Preedit) Span {
        const bytes = self.text.items;
        const begin = boundaryAt(bytes, self.start);
        const end = boundaryAt(bytes, begin + self.length);
        if (end <= begin) return .{ .start = 0, .len = 0 };
        return .{ .start = cellsIn(bytes[0..begin]), .len = cellsIn(bytes[begin..end]) };
    }

    /// A span of composition cells, in the grid the cursor sits on.
    pub const Span = struct { start: usize, len: usize };

    fn cellsIn(bytes: []const u8) usize {
        var cells: usize = 0;
        var index: usize = 0;
        while (index < bytes.len) : (index = text.next(bytes, index)) cells += 1;
        return cells;
    }

    /// Largest grapheme boundary at or below `offset`, so a byte offset that
    /// lands inside a sequence cannot split it.
    fn boundaryAt(bytes: []const u8, offset: usize) usize {
        var index: usize = 0;
        while (index < offset and index < bytes.len) index = text.next(bytes, index);
        return index;
    }
};

test "preedit keeps a composition and ends it on empty input" {
    const a = std.testing.allocator;
    var preedit: Preedit = .{};
    defer preedit.deinit(a);
    try preedit.update(a, "\xe3\x81\xab\xe3\x81\xbb\xe3\x82\x93", 1, 2);
    try std.testing.expectEqualStrings("\xe3\x81\xab\xe3\x81\xbb\xe3\x82\x93", preedit.text.items);
    try std.testing.expectEqual(@as(usize, 3), preedit.cellCount());
    try std.testing.expectEqual(@as(usize, 1), preedit.start);
    try std.testing.expectEqual(@as(usize, 2), preedit.length);
    // An empty composition is how a cancelled or finished session reports.
    try preedit.update(a, "", 0, 0);
    try std.testing.expectEqual(@as(usize, 0), preedit.text.items.len);
    try std.testing.expectEqual(@as(usize, 0), preedit.cellCount());
    try std.testing.expectEqual(@as(usize, 0), preedit.start);
}

test "preedit rejects an oversized composition" {
    const a = std.testing.allocator;
    var preedit: Preedit = .{};
    defer preedit.deinit(a);
    const huge = try a.alloc(u8, Preedit.max_bytes + 1);
    defer a.free(huge);
    @memset(huge, 'x');
    try preedit.update(a, huge, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), preedit.text.items.len);
    // A composition at the limit is still accepted.
    try preedit.update(a, huge[0..Preedit.max_bytes], 0, 0);
    try std.testing.expectEqual(Preedit.max_bytes, preedit.text.items.len);
}

test "selection span clamps to the composition and to grapheme boundaries" {
    const a = std.testing.allocator;
    var preedit: Preedit = .{};
    defer preedit.deinit(a);
    // Two ASCII characters, so the second starts at byte 1 and no boundary is
    // inside a sequence.
    try preedit.update(a, "nihongo", 2, 3);
    try std.testing.expectEqual(Preedit.Span{ .start = 2, .len = 3 }, preedit.selectionCells());
    // A region past the end clamps instead of reading beyond the composition.
    try preedit.update(a, "abc", 1, 99);
    try std.testing.expectEqual(Preedit.Span{ .start = 1, .len = 2 }, preedit.selectionCells());
    // A multi-byte composition keeps one cell per character.
    try preedit.update(a, "\u{306b}\u{307b}\u{3093}", 3, 3);
    try std.testing.expectEqual(Preedit.Span{ .start = 1, .len = 1 }, preedit.selectionCells());
    try std.testing.expectEqual(@as(usize, 3), preedit.cellCount());
    // A cancelled composition reports no selection.
    preedit.clear();
    try std.testing.expectEqual(Preedit.Span{ .start = 0, .len = 0 }, preedit.selectionCells());
}

test "composition update survives allocation failure without partial state" {
    const ops = struct {
        fn run(a: Allocator) !void {
            var preedit: Preedit = .{};
            defer preedit.deinit(a);
            try preedit.update(a, "first", 1, 2);
            preedit.update(a, "second", 0, 3) catch |err| {
                // A failed update must end the composition rather than leave it
                // half replaced: drawing part of the new text, or a selection
                // that belonged to it, would show composed text that the input
                // method never reported.
                try std.testing.expectEqual(@as(usize, 0), preedit.text.items.len);
                try std.testing.expectEqual(Preedit.Span{ .start = 0, .len = 0 }, preedit.selectionCells());
                return err;
            };
            try std.testing.expectEqualStrings("second", preedit.text.items);
            try std.testing.expectEqual(Preedit.Span{ .start = 0, .len = 3 }, preedit.selectionCells());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ops.run, .{});
}
