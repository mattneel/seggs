const std = @import("std");
const GapBuffer = @import("gap_buffer.zig").GapBuffer;
const text = @import("../core/text.zig");
const gdata = @import("../core/grapheme_data.zig");
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
    line_starts: std.ArrayList(usize) = .empty,

    pub fn init(a: Allocator, bytes: []const u8) !Document {
        if (bytes.len > max_bytes) return error.FileTooLarge;
        if (!std.unicode.utf8ValidateSlice(bytes) or text.findByte(bytes, 0) != null) return error.NotUtf8Text;
        var line_starts: std.ArrayList(usize) = .empty;
        errdefer line_starts.deinit(a);
        try line_starts.append(a, 0);
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == '\n') try line_starts.append(a, i + 1);
        }
        return .{ .allocator = a, .buffer = try GapBuffer.init(a, bytes), .line_starts = line_starts };
    }

    fn freeEdit(self: *Document, edit: Edit) void {
        self.history_bytes -= edit.removed.len + edit.inserted.len;
        self.allocator.free(edit.removed);
        self.allocator.free(edit.inserted);
    }

    pub fn deinit(self: *Document) void {
        for (self.history.items) |edit| self.freeEdit(edit);
        self.history.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
        self.buffer.deinit();
    }

    pub fn snapshot(self: *const Document, a: Allocator) ![]u8 {
        return self.buffer.copy(a);
    }

    pub fn boundary(self: *const Document, at: usize) bool {
        return at <= self.buffer.len() and (at == self.buffer.len() or self.buffer.byteAt(at) & 0xc0 != 0x80);
    }

    /// Line index (0-based) of the line containing `position`. O(log lines).
    pub fn lineOf(self: *const Document, position: usize) usize {
        const items = self.line_starts.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] <= position) lo = mid else hi = mid;
        }
        return lo;
    }

    pub fn lineCount(self: *const Document) usize {
        return self.line_starts.items.len;
    }

    /// Byte offset of the first character of line `line`, clamped to the last line.
    pub fn lineStartAt(self: *const Document, line: usize) usize {
        const starts = self.line_starts.items;
        return starts[@min(line, starts.len - 1)];
    }

    /// Build the line-start index for `replace(start, end, bytes)` without
    /// mutating the buffer, so an allocation failure leaves the document intact.
    fn buildLineStarts(self: *const Document, start: usize, end: usize, bytes: []const u8) !std.ArrayList(usize) {
        const li = self.lineOf(start);
        const removed_lines = self.lineOf(end) - li;
        var result: std.ArrayList(usize) = .empty;
        errdefer result.deinit(self.allocator);
        try result.appendSlice(self.allocator, self.line_starts.items[0 .. li + 1]);
        var p: usize = 0;
        while (p < bytes.len) : (p += 1) {
            if (bytes[p] == '\n') try result.append(self.allocator, start + p + 1);
        }
        const delta: i64 = @as(i64, @intCast(bytes.len)) - @as(i64, @intCast(end - start));
        for (self.line_starts.items[li + 1 + removed_lines ..]) |pos| {
            try result.append(self.allocator, @intCast(@as(i64, @intCast(pos)) + delta));
        }
        return result;
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
        var new_line_starts = try self.buildLineStarts(start, end, bytes);
        errdefer new_line_starts.deinit(self.allocator);
        try self.buffer.reserve(bytes.len);
        try self.history.ensureUnusedCapacity(self.allocator, 1);
        while (self.history.items.len > self.history_cursor) self.freeEdit(self.history.pop().?);
        self.buffer.remove(start, end);
        try self.buffer.insert(start, bytes);
        self.line_starts.deinit(self.allocator);
        self.line_starts = new_line_starts;
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

    fn scalarStart(self: *const Document, position: usize) usize {
        var p = position - 1;
        while (p > 0 and !self.boundary(p)) : (p -= 1) {}
        return p;
    }

    fn scalarEnd(self: *const Document, at: usize) usize {
        var p = at + 1;
        while (p < self.buffer.len() and !self.boundary(p)) : (p += 1) {}
        return p;
    }

    fn propertyAt(self: *const Document, at: usize) gdata.Property {
        const end = self.scalarEnd(at);
        const len = end - at;
        var buf: [4]u8 = undefined;
        var i: usize = 0;
        while (i < len) : (i += 1) buf[i] = self.buffer.byteAt(at + i);
        const codepoint = std.unicode.utf8Decode(buf[0..len]) catch return .other;
        return gdata.propertyOf(codepoint);
    }

    /// Byte offset of the start of the grapheme cluster ending at `position`.
    pub fn previous(self: *const Document, position: usize) usize {
        if (position == 0) return 0;
        var start = self.scalarStart(position);
        var curr = self.propertyAt(start);
        while (start > 0) {
            const prev_start = self.scalarStart(start);
            const prev = self.propertyAt(prev_start);
            if (gdata.breakBetween(prev, curr)) break;
            curr = prev;
            start = prev_start;
        }
        return start;
    }

    /// Byte offset just past the grapheme cluster starting at `position`.
    pub fn next(self: *const Document, position: usize) usize {
        if (position >= self.buffer.len()) return self.buffer.len();
        var end = self.scalarEnd(position);
        var prev = self.propertyAt(position);
        while (end < self.buffer.len()) {
            const curr = self.propertyAt(end);
            if (gdata.breakBetween(prev, curr)) break;
            prev = curr;
            end = self.scalarEnd(end);
        }
        return end;
    }

    pub fn backspace(self: *Document) !void {
        try self.replace(self.previous(self.cursor), self.cursor, "");
    }

    pub fn delete(self: *Document) !void {
        try self.replace(self.cursor, self.next(self.cursor), "");
    }

    pub fn lineStart(self: *const Document, position: usize) usize {
        return self.line_starts.items[self.lineOf(position)];
    }

    pub fn lineEnd(self: *const Document, position: usize) usize {
        const li = self.lineOf(position);
        const starts = self.line_starts.items;
        if (li + 1 < starts.len) return starts[li + 1] - 1;
        return self.buffer.len();
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
        var new_line_starts = try self.buildLineStarts(edit.at, edit.at + edit.inserted.len, edit.removed);
        errdefer new_line_starts.deinit(self.allocator);
        try self.buffer.reserve(edit.removed.len);
        self.buffer.remove(edit.at, edit.at + edit.inserted.len);
        try self.buffer.insert(edit.at, edit.removed);
        self.line_starts.deinit(self.allocator);
        self.line_starts = new_line_starts;
        self.cursor = edit.at + edit.removed.len;
        self.history_cursor -= 1;
        self.revision +%= 1;
    }

    pub fn redo(self: *Document) !void {
        if (self.history_cursor == self.history.items.len) return;
        const edit = self.history.items[self.history_cursor];
        var new_line_starts = try self.buildLineStarts(edit.at, edit.at + edit.removed.len, edit.inserted);
        errdefer new_line_starts.deinit(self.allocator);
        try self.buffer.reserve(edit.inserted.len);
        self.buffer.remove(edit.at, edit.at + edit.removed.len);
        try self.buffer.insert(edit.at, edit.inserted);
        self.line_starts.deinit(self.allocator);
        self.line_starts = new_line_starts;
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

test "grapheme movement skips combining marks" {
    const a = std.testing.allocator;
    var d = try Document.init(a, "e\xcc\x81x");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), d.next(0));
    try std.testing.expectEqual(@as(usize, 3), d.previous(4));
    try std.testing.expectEqual(@as(usize, 0), d.previous(3));
    d.cursor = 4;
    try d.backspace();
    try d.backspace();
    const bytes = try d.snapshot(a);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("", bytes);
}

test "grapheme clusters include flags and CRLF" {
    const a = std.testing.allocator;
    var flag = try Document.init(a, "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8x");
    defer flag.deinit();
    try std.testing.expectEqual(@as(usize, 8), flag.next(0));
    try std.testing.expectEqual(@as(usize, 8), flag.previous(9));
    var crlf = try Document.init(a, "a\r\nb");
    defer crlf.deinit();
    try std.testing.expectEqual(@as(usize, 1), crlf.next(0));
    try std.testing.expectEqual(@as(usize, 3), crlf.next(1));
    try std.testing.expectEqual(@as(usize, 1), crlf.previous(3));
}

test "line index tracks edits, undo, and redo" {
    const a = std.testing.allocator;
    var d = try Document.init(a, "ab\ncd\nef");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), d.lineCount());
    try std.testing.expectEqual(@as(usize, 0), d.lineOf(0));
    try std.testing.expectEqual(@as(usize, 1), d.lineOf(3));
    try std.testing.expectEqual(@as(usize, 2), d.lineOf(7));
    try std.testing.expectEqual(@as(usize, 0), d.lineStart(2));
    try std.testing.expectEqual(@as(usize, 2), d.lineEnd(0));
    try std.testing.expectEqual(@as(usize, 8), d.lineEnd(7));
    try d.replace(4, 4, "X\nY");
    try std.testing.expectEqual(@as(usize, 4), d.lineCount());
    try std.testing.expectEqual(@as(usize, 1), d.lineOf(4));
    try std.testing.expectEqual(@as(usize, 2), d.lineOf(6));
    try std.testing.expectEqual(@as(usize, 3), d.lineOf(10));
    try std.testing.expectEqual(@as(usize, 3), d.lineStart(4));
    try std.testing.expectEqual(@as(usize, 5), d.lineEnd(4));
    try d.undo();
    try std.testing.expectEqual(@as(usize, 3), d.lineCount());
    try std.testing.expectEqual(@as(usize, 2), d.lineOf(7));
    try d.redo();
    try std.testing.expectEqual(@as(usize, 4), d.lineCount());
    try std.testing.expectEqual(@as(usize, 2), d.lineOf(6));
}

fn editOps(a: Allocator) !void {
    var d = try Document.init(a, "hello world");
    defer d.deinit();
    try d.replace(0, 5, "hi");
    try d.insert("!");
    try d.undo();
    try d.redo();
    const bytes = try d.snapshot(a);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("hi! world", bytes);
}

test "every allocation failure during editing is reported without leak or corruption" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, editOps, .{});
}
