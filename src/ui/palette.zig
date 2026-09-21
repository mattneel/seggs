//! The agent's commands, as a palette's contents.
//!
//! ACP reports the commands an agent accepts (`available_commands_update`) and
//! they are not a list to print: a reader picks one and it goes into the prompt,
//! which is what a menu is for. So this is the join between the two existing
//! vocabularies and nothing more - `session_state.Command` in, `menu.Item` out -
//! and the menu widget decides where the list goes, how it scrolls, and what
//! happens when the reader types into it.
//!
//! The hint matters as much as the row: a command that wants something typed
//! with it says so in `input.hint`, and that is what a future key puts in the
//! composer when the row is chosen. Without it a reader picks `research` and
//! waits for an agent that is waiting for them.

const std = @import("std");
const session_state = @import("../acp/session_state.zig");
const menu = @import("menu.zig");
const Allocator = std.mem.Allocator;

/// What the palette is called when it opens.
pub const title = "Commands";

/// One menu row per command the session advertises.
///
/// The label carries the slash a reader types, because the row is what they
/// will type next; the detail is the description the agent gave, and falls back
/// to the hint when the agent sent no description - a row with a description of
/// "research" is less useful than one that says what the command wants.
pub fn items(commands: []const session_state.Command, a: Allocator) ![]menu.Item {
    const rows = try a.alloc(menu.Item, commands.len);
    for (commands, 0..) |command, index| {
        rows[index] = .{
            .label = try std.fmt.allocPrint(a, "/{s}", .{command.name}),
            .detail = if (command.description.len != 0) command.description else command.hint,
            // The key is the index rather than the name: the menu reports the
            // row that was chosen, and a name is what `hint` is asked about.
            .key = index,
        };
    }
    return rows;
}

/// What the composer should hold once this row is chosen: the hint the agent
/// gave for the command's input, or nothing when the command wants nothing
/// typed. An empty answer is a real answer - a command that takes no arguments
/// is complete as it stands.
pub fn hint(commands: []const session_state.Command, key: usize) []const u8 {
    if (key >= commands.len) return "";
    return commands[key].hint;
}

/// The command a row's key names, for a caller that needs more than the hint.
pub fn commandAt(commands: []const session_state.Command, key: usize) ?session_state.Command {
    if (key >= commands.len) return null;
    return commands[key];
}

test "the palette is the commands, labelled the way they are typed" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();

    const commands = [_]session_state.Command{
        .{ .name = "compact", .description = "Fold the context", .hint = "" },
        .{ .name = "research", .description = "", .hint = "what to look up" },
    };
    const rows = try items(&commands, frame);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("/compact", rows[0].label);
    try std.testing.expectEqualStrings("Fold the context", rows[0].detail);
    // A command with no description shows what it wants typed instead of
    // showing nothing: the row is a thing to choose, not a label.
    try std.testing.expectEqualStrings("what to look up", rows[1].detail);
    try std.testing.expectEqual(@as(usize, 0), rows[0].key);
    try std.testing.expectEqual(@as(usize, 1), rows[1].key);
    try std.testing.expectEqualStrings("Commands", title);

    // Chosen, a row says what to put in the composer, and a command that takes
    // nothing says so by saying nothing.
    try std.testing.expectEqualStrings("", hint(&commands, 0));
    try std.testing.expectEqualStrings("what to look up", hint(&commands, 1));
    try std.testing.expectEqualStrings("", hint(&commands, 7));
    try std.testing.expectEqualStrings("research", commandAt(&commands, 1).?.name);
    try std.testing.expectEqual(@as(?session_state.Command, null), commandAt(&commands, 7));

    // A session that advertises nothing has no rows, which is what makes the
    // key that opens this a key that does nothing rather than a key that opens
    // an empty box.
    try std.testing.expectEqual(@as(usize, 0), (try items(&.{}, frame)).len);
}
