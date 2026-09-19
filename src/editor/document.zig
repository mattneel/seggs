const std = @import("std");
const GapBuffer = @import("gap_buffer.zig").GapBuffer;
const text = @import("../core/text.zig");
const Allocator = std.mem.Allocator;

pub const Document = struct {
    pub const max_bytes = 8 * 1024 * 1024;
    const Edit = struct { at: usize, removed: []u8, inserted: []u8 };
    allocator: Allocator,
    buffer: GapBuffer,
    cursor: usize = 0,
    revision: u64 = 0,
    history: std.ArrayList(Edit) = .empty,
    history_cursor: usize = 0,
    history_bytes: usize = 0,

    pub fn init(a: Allocator, bytes: []const u8) !Document {
        if (bytes.len > max_bytes) return error.FileTooLarge;
        if (!std.unicode.utf8ValidateSlice(bytes) or text.findByte(bytes, 0) != null) return error.NotUtf8Text;
        return .{ .allocator = a, .buffer = try GapBuffer.init(a, bytes) };
    }

    fn freeEdit(self: *Document, edit: Edit) void {
        self.history_bytes -= edit.removed.len + edit.inserted.len;
        self.allocator.free(edit.removed);
        self.allocator.free(edit.inserted);
    }

    pub fn deinit(self: *Document) void {
        for (self.history.items) |edit| self.freeEdit(edit);
        self.history.deinit(self.allocator);
        self.buffer.deinit();
    }

    pub fn snapshot(self: *const Document, a: Allocator) ![]u8 {
        return self.buffer.copy(a);
    }

    pub fn boundary(self: *const Document, at: usize) bool {
        return at <= self.buffer.len() and (at == self.buffer.len() or self.buffer.byteAt(at) & 0xc0 != 0x80);
    }

    pub fn replace(self: *Document, start: usize, end: usize, bytes: []const u8) !void {
        if (start > end or !self.boundary(start) or !self.boundary(end)) return error.InvalidRange;
        if (!std.unicode.utf8ValidateSlice(bytes) or text.findByte(bytes, 0) != null) return error.NotUtf8Text;
        if (self.buffer.len() - (end - start) + bytes.len > max_bytes) return error.FileTooLarge;
        if (start == end and bytes.len == 0) return;
        const removed = try self.allocator.alloc(u8, end - start);
        errdefer self.allocator.free(removed);
        for (removed, 0..) |*byte, i| byte.* = self.buffer.byteAt(start + i);
        const inserted = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(inserted);
        try self.buffer.reserve(bytes.len);
        try self.history.ensureUnusedCapacity(self.allocator, 1);
        while (self.history.items.len > self.history_cursor) self.freeEdit(self.history.pop().?);
        self.buffer.remove(start, end);
        try self.buffer.insert(start, bytes);
        self.history.appendAssumeCapacity(.{ .at = start, .removed = removed, .inserted = inserted });
        self.history_bytes += removed.len + inserted.len;
        while (self.history.items.len > 128 or (self.history_bytes > 16 * 1024 * 1024 and self.history.items.len > 1)) {
            self.freeEdit(self.history.orderedRemove(0));
        }
        self.history_cursor = self.history.items.len;
        self.cursor = start + bytes.len;
        self.revision +%= 1;
    }

    pub fn insert(self: *Document, bytes: []const u8) !void {
        try self.replace(self.cursor, self.cursor, bytes);
    }

    pub fn previous(self: *const Document, position: usize) usize {
        if (position == 0) return 0;
        var p = position - 1;
        while (p > 0 and !self.boundary(p)) : (p -= 1) {}
        return p;
    }

    pub fn next(self: *const Document, position: usize) usize {
        if (position >= self.buffer.len()) return self.buffer.len();
        var p = position + 1;
        while (p < self.buffer.len() and !self.boundary(p)) : (p += 1) {}
        return p;
    }

    pub fn backspace(self: *Document) !void {
        try self.replace(self.previous(self.cursor), self.cursor, "");
    }

    pub fn delete(self: *Document) !void {
        try self.replace(self.cursor, self.next(self.cursor), "");
    }

    pub fn lineStart(self: *const Document, position: usize) usize {
        var p = position;
        while (p > 0 and self.buffer.byteAt(p - 1) != '\n') : (p -= 1) {}
        return p;
    }

    pub fn lineEnd(self: *const Document, position: usize) usize {
        var p = position;
        while (p < self.buffer.len() and self.buffer.byteAt(p) != '\n') : (p += 1) {}
        return p;
    }

    pub fn moveVertical(self: *Document, down: bool) void {
        const start = self.lineStart(self.cursor);
        var column: usize = 0;
        var p = start;
        while (p < self.cursor) : (p = self.next(p)) column += 1;
        var target = start;
        if (down) {
            target = self.lineEnd(self.cursor);
            if (target == self.buffer.len()) return;
            target += 1;
        } else {
            if (start == 0) return;
            target = self.lineStart(start - 1);
        }
        while (column > 0 and target < self.buffer.len() and self.buffer.byteAt(target) != '\n') : (column -= 1) {
            target = self.next(target);
        }
        self.cursor = target;
    }

    pub fn undo(self: *Document) !void {
        if (self.history_cursor == 0) return;
        const edit = self.history.items[self.history_cursor - 1];
        try self.buffer.reserve(edit.removed.len);
        self.buffer.remove(edit.at, edit.at + edit.inserted.len);
        try self.buffer.insert(edit.at, edit.removed);
        self.cursor = edit.at + edit.removed.len;
        self.history_cursor -= 1;
        self.revision +%= 1;
    }

    pub fn redo(self: *Document) !void {
        if (self.history_cursor == self.history.items.len) return;
        const edit = self.history.items[self.history_cursor];
        try self.buffer.reserve(edit.inserted.len);
        self.buffer.remove(edit.at, edit.at + edit.removed.len);
        try self.buffer.insert(edit.at, edit.inserted);
        self.cursor = edit.at + edit.inserted.len;
        self.history_cursor += 1;
        self.revision +%= 1;
    }
};

test "UTF-8 edit, undo, redo, and divergent history" {
    const a = std.testing.allocator;
    var d = try Document.init(a, "a\xc3\xa9\nend");
    defer d.deinit();
    d.cursor = 3;
    try d.backspace();
    try d.undo();
    try d.redo();
    try d.undo();
    try d.insert("!");
    try d.redo();
    const bytes = try d.snapshot(a);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("a\xc3\xa9!\nend", bytes);
    try std.testing.expectError(error.InvalidRange, d.replace(2, 3, "x"));
}

test "vertical movement and invalid input" {
    const a = std.testing.allocator;
    var d = try Document.init(a, "abcd\nx\n1234");
    defer d.deinit();
    d.cursor = 3;
    d.moveVertical(true);
    try std.testing.expectEqual(@as(usize, 6), d.cursor);
    d.moveVertical(false);
    try std.testing.expectEqual(@as(usize, 1), d.cursor);
    try std.testing.expectError(error.NotUtf8Text, d.insert("\xff"));
}
