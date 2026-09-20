const std = @import("std");
const text = @import("../core/text.zig");

/// ACP stdio uses newline-delimited JSON, not LSP Content-Length headers.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    pub const max_frame_bytes = 1024 * 1024;

    pub fn init(a: std.mem.Allocator) Decoder {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Decoder) void {
        self.buffer.deinit(self.allocator);
    }

    /// The transport calls next() until empty before the next feed().
    pub fn feed(self: *Decoder, chunk: []const u8) !void {
        if (self.buffer.items.len + chunk.len > max_frame_bytes + 16 * 1024) return error.FrameTooLarge;
        try self.buffer.appendSlice(self.allocator, chunk);
        if (text.findByte(self.buffer.items, '\n') == null and self.buffer.items.len > max_frame_bytes) return error.FrameTooLarge;
    }

    pub fn next(self: *Decoder) !?[]u8 {
        const end = text.findByte(self.buffer.items, '\n') orelse return null;
        if (end > max_frame_bytes) return error.FrameTooLarge;
        const trim_end = if (end > 0 and self.buffer.items[end - 1] == '\r') end - 1 else end;
        const result = try self.allocator.dupe(u8, self.buffer.items[0..trim_end]);
        const tail = self.buffer.items.len - end - 1;
        std.mem.copyForwards(u8, self.buffer.items[0..tail], self.buffer.items[end + 1 ..]);
        self.buffer.items.len = tail;
        return result;
    }
};

test "fragmented frames, coalesced frames, CRLF, escaped newline" {
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();
    try d.feed("{\"a\":\"x\\n");
    try std.testing.expect((try d.next()) == null);
    try d.feed("y\"}\r\n{}\n");
    const first = (try d.next()).?;
    defer a.free(first);
    try std.testing.expectEqualStrings("{\"a\":\"x\\ny\"}", first);
    const second = (try d.next()).?;
    defer a.free(second);
    try std.testing.expectEqualStrings("{}", second);
    try std.testing.expect((try d.next()) == null);
}

test "oversize frame fails closed" {
    const a = std.testing.allocator;
    var d = Decoder.init(a);
    defer d.deinit();
    const bytes = try a.alloc(u8, Decoder.max_frame_bytes + 1);
    defer a.free(bytes);
    @memset(bytes, 'x');
    try std.testing.expectError(error.FrameTooLarge, d.feed(bytes));
}

fn decodeOps(a: std.mem.Allocator) !void {
    var d = Decoder.init(a);
    defer d.deinit();
    try d.feed("{\"a\":\"x\\n");
    try std.testing.expect((try d.next()) == null);
    try d.feed("y\"}\r\n{}\n");
    const first = (try d.next()) orelse return error.MissingFrame;
    defer a.free(first);
    try std.testing.expectEqualStrings("{\"a\":\"x\\ny\"}", first);
    const second = (try d.next()) orelse return error.MissingFrame;
    defer a.free(second);
    try std.testing.expectEqualStrings("{}", second);
    try std.testing.expect((try d.next()) == null);
}

test "every allocation failure in the decoder is reported without leak or corruption" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeOps, .{});
}
