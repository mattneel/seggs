//! Breaking text into rows.
//!
//! The first piece of what should become a component library: given bytes and a
//! column count, what rows do they become? It is pure, so it is tested for its
//! own sake rather than through a frame.
const std = @import("std");
const text = @import("../core/text.zig");
const Allocator = std.mem.Allocator;

/// Break `bytes` into rows of at most `columns` characters, honouring the
/// newlines that are already there. The spans borrow `bytes`; the list owns its
/// own array and is the caller's to clear or release.
pub fn spans(a: Allocator, bytes: []const u8, columns: usize, out: *std.ArrayList([]const u8)) !void {
    const width = @max(1, columns);
    var start: usize = 0;
    var pos: usize = 0;
    var column: usize = 0;
    while (pos < bytes.len) {
        if (bytes[pos] == '\n' or column >= width) {
            try out.append(a, bytes[start..pos]);
            if (bytes[pos] == '\n') pos += 1;
            start = pos;
            column = 0;
            continue;
        }
        pos = text.next(bytes, pos);
        column += 1;
    }
    try out.append(a, bytes[start..]);
}

/// How many rows `bytes` needs at `columns`, which is what a caller sizing a
/// row has to know before it draws anything.
pub fn rowCount(bytes: []const u8, columns: usize) usize {
    const width = @max(1, columns);
    var rows: usize = 1;
    var pos: usize = 0;
    var column: usize = 0;
    while (pos < bytes.len) {
        if (bytes[pos] == '\n') {
            rows += 1;
            pos += 1;
            column = 0;
            continue;
        }
        if (column >= width) {
            rows += 1;
            column = 0;
        }
        pos = text.next(bytes, pos);
        column += 1;
    }
    return rows;
}

test "text breaks on the column it is given and on its own newlines" {
    const a = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(a);

    try spans(a, "abcdef", 3, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("abc", list.items[0]);
    try std.testing.expectEqualStrings("def", list.items[1]);

    list.clearRetainingCapacity();
    try spans(a, "ab\ncd", 8, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("ab", list.items[0]);
    try std.testing.expectEqualStrings("cd", list.items[1]);

    // A word longer than the row still has to go somewhere.
    list.clearRetainingCapacity();
    try spans(a, "abcdefgh", 3, &list);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);

    // Breaking counts characters, not bytes: a multi-byte codepoint is one
    // column and must not be cut in half.
    list.clearRetainingCapacity();
    try spans(a, "ééé", 2, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("éé", list.items[0]);
    try std.testing.expectEqualStrings("é", list.items[1]);
}

test "a row can be counted before it is drawn" {
    try std.testing.expectEqual(@as(usize, 1), rowCount("abc", 8));
    try std.testing.expectEqual(@as(usize, 2), rowCount("abcdefgh", 4));
    try std.testing.expectEqual(@as(usize, 3), rowCount("a\nb\nc", 8));
    try std.testing.expectEqual(@as(usize, 2), rowCount("abc\ndef", 8));
    // An empty row is still a row.
    try std.testing.expectEqual(@as(usize, 1), rowCount("", 8));
}
