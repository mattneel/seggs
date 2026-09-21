//! One way to keep a value from being unbounded.
//!
//! Every reader beside this one faces the same problem: an agent can put a file
//! body where a label belongs, and a record that holds the whole file is the
//! dump the interface exists to avoid. The rule is the same everywhere - a
//! value keeps its first line and says how many bytes it left out, because a
//! reader who cannot see that a value continues reads a cut as the value.
//!
//! `tool_call.zig` carries its own copy of this, older than this file. Folding
//! that one in is a change to a module this reader does not own; the new
//! readers share this one so that at least the convention cannot drift twice.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `text` no longer than `limit`, with what was left out said out loud. A
/// multi-line value keeps its first line, and the cut never lands in the middle
/// of a character.
pub fn bounded(a: Allocator, text: []const u8, limit: usize) ![]u8 {
    // A value that ends in a newline is the same value without it, and the note
    // is about content rather than about line endings.
    const value = std.mem.trimEnd(u8, text, "\r\n");
    if (value.len == 0) return &.{};
    const line = firstLine(value);
    var cut = @min(line.len, limit);
    // Never cut a character in half: the next byte starts one.
    while (cut < line.len and line[cut] & 0xc0 == 0x80) : (cut += 1) {}
    const shown = line[0..cut];
    if (shown.len == value.len) return a.dupe(u8, value);
    return std.fmt.allocPrint(a, "{s} … ({d} bytes omitted)", .{ shown, value.len - shown.len });
}

/// The first line of a value, without the line ending.
pub fn firstLine(text: []const u8) []const u8 {
    const stop = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    const line = text[0..stop];
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

test "a value keeps its first line and says what it left out" {
    const a = std.testing.allocator;
    const line = try bounded(a, "src/app.zig", 200);
    defer a.free(line);
    try std.testing.expectEqualStrings("src/app.zig", line);

    // A file body where a label belongs is a label and a count, not a file.
    const body = try bounded(a, "fn main() void {\n  a lot of code\n}\n", 200);
    defer a.free(body);
    try std.testing.expectEqualStrings("fn main() void { … (18 bytes omitted)", body);

    // A value that fits keeps all of itself, line endings aside.
    const whole = try bounded(a, "one line\n", 200);
    defer a.free(whole);
    try std.testing.expectEqualStrings("one line", whole);

    // A value past the limit is cut at the limit rather than at its first line.
    const long = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    const cut = try bounded(a, long, 8);
    defer a.free(cut);
    try std.testing.expectEqualStrings("xxxxxxxx … (32 bytes omitted)", cut);

    // A cut never lands inside a character: this one is four bytes, so the cut
    // moves to the start of the next one rather than through it.
    const wide = try bounded(a, "🙂🙂🙂", 5);
    defer a.free(wide);
    try std.testing.expectEqualStrings("🙂🙂 … (4 bytes omitted)", wide);
}
