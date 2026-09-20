const std = @import("std");
const Allocator = std.mem.Allocator;

/// Byte offsets are the storage contract. Document validates UTF-8 boundaries.
pub const GapBuffer = struct {
    allocator: Allocator,
    storage: []u8,
    gap_start: usize,
    gap_end: usize,

    pub fn init(allocator: Allocator, bytes: []const u8) !GapBuffer {
        const storage = try allocator.alloc(u8, @max(256, bytes.len + 128));
        @memcpy(storage[0..bytes.len], bytes);
        return .{ .allocator = allocator, .storage = storage, .gap_start = bytes.len, .gap_end = storage.len };
    }

    pub fn deinit(self: *GapBuffer) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn len(self: *const GapBuffer) usize {
        return self.storage.len - (self.gap_end - self.gap_start);
    }

    pub fn byteAt(self: *const GapBuffer, index: usize) u8 {
        std.debug.assert(index < self.len());
        return self.storage[if (index < self.gap_start) index else index + self.gap_end - self.gap_start];
    }

    pub fn copy(self: *const GapBuffer, allocator: Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.len());
        @memcpy(out[0..self.gap_start], self.storage[0..self.gap_start]);
        @memcpy(out[self.gap_start..], self.storage[self.gap_end..]);
        return out;
    }

    pub fn reserve(self: *GapBuffer, extra: usize) !void {
        if (self.gap_end - self.gap_start >= extra) return;
        const size = @max(self.storage.len * 2, self.len() + extra + 128);
        const replacement = try self.allocator.alloc(u8, size);
        const tail_len = self.storage.len - self.gap_end;
        @memcpy(replacement[0..self.gap_start], self.storage[0..self.gap_start]);
        @memcpy(replacement[size - tail_len ..], self.storage[self.gap_end..]);
        self.allocator.free(self.storage);
        self.storage = replacement;
        self.gap_end = size - tail_len;
    }

    fn moveGap(self: *GapBuffer, position: usize) void {
        std.debug.assert(position <= self.len());
        if (position < self.gap_start) {
            const count = self.gap_start - position;
            std.mem.copyBackwards(u8, self.storage[self.gap_end - count .. self.gap_end], self.storage[position..self.gap_start]);
            self.gap_start -= count;
            self.gap_end -= count;
        } else if (position > self.gap_start) {
            const count = position - self.gap_start;
            std.mem.copyForwards(u8, self.storage[self.gap_start .. self.gap_start + count], self.storage[self.gap_end .. self.gap_end + count]);
            self.gap_start += count;
            self.gap_end += count;
        }
    }

    pub fn insert(self: *GapBuffer, at: usize, bytes: []const u8) !void {
        try self.reserve(bytes.len);
        self.moveGap(at);
        @memcpy(self.storage[self.gap_start .. self.gap_start + bytes.len], bytes);
        self.gap_start += bytes.len;
    }

    pub fn remove(self: *GapBuffer, start: usize, end: usize) void {
        std.debug.assert(start <= end and end <= self.len());
        self.moveGap(start);
        self.gap_end += end - start;
    }
};

test "gap moves in both directions and grows" {
    const a = std.testing.allocator;
    var b = try GapBuffer.init(a, "ac");
    defer b.deinit();
    try b.insert(1, "b");
    try b.insert(0, "0");
    b.remove(1, 2);
    try b.insert(b.len(), "!");
    const bytes = try b.copy(a);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("0bc!", bytes);
    const large: [1024]u8 = @splat('x');
    try b.insert(2, &large);
    try std.testing.expectEqual(@as(usize, 1028), b.len());
    try std.testing.expectEqual(@as(u8, 'c'), b.byteAt(1026));
}

fn growthOps(a: Allocator) !void {
    var b = try GapBuffer.init(a, "abc");
    defer b.deinit();
    const big: [300]u8 = @splat('x');
    try b.insert(0, &big);
    try b.insert(b.len(), "!");
    const bytes = try b.copy(a);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, 304), b.len());
    try std.testing.expectEqual(@as(u8, '!'), bytes[303]);
}

test "every allocation failure is reported without leak or corruption" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, growthOps, .{});
}
