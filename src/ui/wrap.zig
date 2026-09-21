//! Breaking text into rows.
//!
//! The first piece of what should become a component library: given bytes and a
//! column count, what rows do they become? It is pure, so it is tested for its
//! own sake rather than through a frame.
const std = @import("std");
const text = @import("../core/text.zig");
const Allocator = std.mem.Allocator;

/// Where a row of `width` should end when it would otherwise break inside a
/// word: the last space that fits, or nowhere when the row is one long word.
/// Returning null means "break at the column", which is what a word longer than
/// the row needs.
fn breakAt(bytes: []const u8, start: usize, pos: usize) ?usize {
    var candidate: ?usize = null;
    var index = start;
    while (index < pos) {
        if (bytes[index] == ' ') candidate = index;
        index = text.next(bytes, index);
    }
    return candidate;
}

/// Break `bytes` into rows of at most `columns` characters, honouring the
/// newlines that are already there and preferring to break between words. The
/// spans borrow `bytes`; the list owns its own array and is the caller's to
/// clear or release.
pub fn spans(a: Allocator, bytes: []const u8, columns: usize, out: *std.ArrayList([]const u8)) !void {
    const width = @max(1, columns);
    var start: usize = 0;
    var pos: usize = 0;
    var column: usize = 0;
    while (pos < bytes.len) {
        // A newline is where the text itself says the row ends.
        if (bytes[pos] == '\n') {
            try out.append(a, bytes[start..pos]);
            pos += 1;
            start = pos;
            column = 0;
            continue;
        }
        if (column >= width) {
            // A break inside a word is the last resort: a reader notices a word
            // cut in half far more than a slightly shorter row.
            const cut = breakAt(bytes, start, pos) orelse pos;
            try out.append(a, bytes[start..cut]);
            start = if (cut < pos) cut + 1 else cut;
            pos = start;
            column = 0;
            continue;
        }
        pos = text.next(bytes, pos);
        column += 1;
    }
    try out.append(a, bytes[start..]);
}

/// `bytes` shortened to fit `columns`, with an ellipsis where it was cut.
///
/// A row in a list is one line: a filename that wraps is a filename whose
/// neighbours move, and a navigator that reflows as names appear is one nobody
/// can scan. The result points into `buffer`, which must outlive it.
pub fn elide(buffer: []u8, bytes: []const u8, columns: usize) []const u8 {
    const width = @max(1, columns);
    const cells = cellCount(bytes);
    if (cells <= width) return bytes;
    // One column of the budget is the ellipsis itself.
    const kept = width - 1;
    var index: usize = 0;
    var taken: usize = 0;
    while (taken < kept and index < bytes.len) : (taken += 1) index = text.next(bytes, index);
    const slice = buffer[0..@min(buffer.len, index + 3)];
    @memcpy(slice[0..index], bytes[0..index]);
    @memcpy(slice[index..][0..3], "…");
    return slice;
}

fn cellCount(bytes: []const u8) usize {
    var cells: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) : (index = text.next(bytes, index)) cells += 1;
    return cells;
}

/// How many rows `bytes` needs at `columns`, which is what a caller sizing a
/// row has to know before it draws anything.
pub fn rowCount(bytes: []const u8, columns: usize) usize {
    const width = @max(1, columns);
    var rows: usize = 1;
    var start: usize = 0;
    var pos: usize = 0;
    var column: usize = 0;
    while (pos < bytes.len) {
        if (bytes[pos] == '\n') {
            rows += 1;
            pos += 1;
            start = pos;
            column = 0;
            continue;
        }
        if (column >= width) {
            // The same break the renderer takes, so a box is never sized for a
            // different arrangement than the one it holds.
            const cut = breakAt(bytes, start, pos) orelse pos;
            rows += 1;
            start = if (cut < pos) cut + 1 else cut;
            pos = start;
            column = 0;
            continue;
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

test "rows break between words when there is a word boundary to use" {
    const a = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(a);
    try spans(a, "hello world", 8, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("hello", list.items[0]);
    try std.testing.expectEqualStrings("world", list.items[1]);

    // A single word longer than the row still has to be placed.
    list.clearRetainingCapacity();
    try spans(a, "hello wonderful", 8, &list);
    try std.testing.expectEqualStrings("hello", list.items[0]);
    try std.testing.expectEqualStrings("wonderfu", list.items[1]);
    try std.testing.expectEqualStrings("l", list.items[2]);

    // Counting rows has to take the same breaks, or a box is sized for one
    // arrangement and holds another.
    try std.testing.expectEqual(@as(usize, 2), rowCount("hello world", 8));
    try std.testing.expectEqual(@as(usize, 3), rowCount("hello wonderful", 8));
    try std.testing.expectEqual(@as(usize, 2), rowCount("hello\nworld", 40));
}

test "a name too long for its row is cut, not wrapped" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("src", elide(&buffer, "src", 8));
    // Eight columns, seven kept, then the ellipsis.
    const cut = elide(&buffer, "src/gpu/renderer.zig", 8);
    try std.testing.expectEqual(@as(usize, 8), cellCount(cut));
    try std.testing.expect(std.mem.endsWith(u8, cut, "…"));
    try std.testing.expect(std.mem.startsWith(u8, cut, "src/gpu"));
}

test "a row can be counted before it is drawn" {
    try std.testing.expectEqual(@as(usize, 1), rowCount("abc", 8));
    try std.testing.expectEqual(@as(usize, 2), rowCount("abcdefgh", 4));
    try std.testing.expectEqual(@as(usize, 3), rowCount("a\nb\nc", 8));
    try std.testing.expectEqual(@as(usize, 2), rowCount("abc\ndef", 8));
    // An empty row is still a row.
    try std.testing.expectEqual(@as(usize, 1), rowCount("", 8));
}
