const std = @import("std");

pub fn findByte(bytes: []const u8, byte: u8) ?usize {
    for (bytes, 0..) |value, i| if (value == byte) return i;
    return null;
}

pub fn isBoundary(bytes: []const u8, at: usize) bool {
    return at <= bytes.len and (at == bytes.len or bytes[at] & 0xc0 != 0x80);
}

pub fn previous(bytes: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var p = @min(at, bytes.len) - 1;
    while (p > 0 and bytes[p] & 0xc0 == 0x80) : (p -= 1) {}
    return p;
}

pub fn next(bytes: []const u8, at: usize) usize {
    if (at >= bytes.len) return bytes.len;
    var p = at + 1;
    while (p < bytes.len and bytes[p] & 0xc0 == 0x80) : (p += 1) {}
    return p;
}

pub fn prefixBoundary(bytes: []const u8, limit: usize) usize {
    var n = @min(bytes.len, limit);
    while (n > 0 and !isBoundary(bytes, n)) : (n -= 1) {}
    return n;
}

test "UTF-8 boundaries do not split scalars" {
    const s = "a\xc3\xa9\xf0\x9f\xa5\x9a";
    try std.testing.expectEqual(@as(usize, 3), next(s, 1));
    try std.testing.expectEqual(@as(usize, 3), previous(s, 7));
    try std.testing.expectEqual(@as(usize, 3), prefixBoundary(s, 6));
    try std.testing.expect(!isBoundary(s, 2));
}
