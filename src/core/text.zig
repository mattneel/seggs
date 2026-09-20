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

/// Decode the UTF-8 codepoint at `at`, or U+FFFD on invalid/truncated input.
pub fn decode(bytes: []const u8, at: usize) u21 {
    if (at >= bytes.len) return 0xFFFD;
    const len = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return 0xFFFD;
    if (at + len > bytes.len) return 0xFFFD;
    return switch (len) {
        1 => bytes[at],
        2 => std.unicode.utf8Decode2(bytes[at..][0..2].*) catch 0xFFFD,
        3 => std.unicode.utf8Decode3(bytes[at..][0..3].*) catch 0xFFFD,
        4 => std.unicode.utf8Decode4(bytes[at..][0..4].*) catch 0xFFFD,
        else => 0xFFFD,
    };
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
