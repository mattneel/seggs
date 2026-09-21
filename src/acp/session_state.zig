//! What a session says about itself, other than what it is doing.
//!
//! These updates are not events in a transcript and not a list that grows: each
//! one replaces the last, because a context count is the current count and not
//! a history of counts. So there is one record of each and no list, and the
//! interface reads the latest without the client having to remember what came
//! before. That is `usage_update`, `compaction_update`, and
//! `available_commands_update`, which are the ones with a payload worth a
//! record; a mode, a title and a timestamp are single strings and live on the
//! client itself.
//!
//! The bounds are the usual style: named limits, named errors, everything
//! owned by the caller and released by the matching `deinit`.

const std = @import("std");
const rpc = @import("protocol.zig");
const limits = @import("limits.zig");
const Allocator = std.mem.Allocator;

/// How full a session's context is, and what it has cost. `used` and `size` are
/// the two numbers that answer "how much room is left", which is the question a
/// reader has about a long session.
pub const Usage = struct {
    /// Tokens currently in the context.
    used: u64,
    /// Tokens the context window holds.
    size: u64,
    /// Cumulative cost, when the agent reports one.
    cost: ?Cost,
};

/// What a session has cost, in a currency the agent names.
pub const Cost = struct { amount: f64, currency: []const u8 };

/// Whether a session is folding its context, and why it could not. A compaction
/// is transient: the status is worth showing while it happens, and the record
/// of it is replaced by the next one rather than accumulated.
pub const Compaction = struct {
    /// The agent's id for this compaction.
    id: []const u8,
    status: Status,
    /// Why a failed compaction failed, when the agent said.
    reason: []const u8,
};

/// Where a compaction has got to. `other` is a status this does not recognise,
/// which is not the same as one that has not started.
pub const Status = enum { in_progress, completed, failed, cancelled, other };

/// A command an agent accepts, which is what a reader picks from rather than
/// typing blind.
pub const Command = struct {
    name: []const u8,
    description: []const u8,
    /// What the command wants typed with it, when it wants anything.
    hint: []const u8,
};

/// The most commands one session may advertise. This is a menu, and a menu
/// longer than this is not one.
pub const max_commands: usize = 64;

/// The most bytes a command's name or description may take.
pub const max_command_bytes: usize = 256;

/// The most bytes a compaction id or a session title may take.
pub const max_id_bytes: usize = 256;

/// The most bytes a compaction's failure reason may take.
pub const max_error_bytes: usize = 512;

/// The most bytes a currency code may take. ISO 4217 uses three.
pub const max_currency_bytes: usize = 16;

/// Read a `usage_update`. Errors are `error.MalformedUsage` when `used` or
/// `size` is not a count, which is what makes the record worth keeping at all;
/// a cost that cannot be read is left out rather than taking the counts down
/// with it, because the counts are the part a reader came for.
pub fn parseUsage(a: Allocator, update: rpc.Value) !Usage {
    const used = count(rpc.field(update, "used") orelse return error.MalformedUsage) orelse return error.MalformedUsage;
    const size = count(rpc.field(update, "size") orelse return error.MalformedUsage) orelse return error.MalformedUsage;
    var usage: Usage = .{ .used = used, .size = size, .cost = null };
    errdefer deinitUsage(&usage, a);
    const cost = rpc.field(update, "cost") orelse return usage;
    if (cost != .object) return usage;
    const amount = number(rpc.field(cost, "amount") orelse return usage) orelse return usage;
    usage.cost = .{
        .amount = amount,
        .currency = try limits.bounded(a, rpc.str(cost, "currency"), max_currency_bytes),
    };
    return usage;
}

/// Release a usage record. The record is emptied as it goes, so releasing one
/// twice is a no-op rather than a fault.
pub fn deinitUsage(usage: *Usage, a: Allocator) void {
    if (usage.cost) |cost| {
        if (cost.currency.len != 0) a.free(cost.currency);
    }
    usage.* = .{ .used = 0, .size = 0, .cost = null };
}

/// Read a `compaction_update`. Errors are `error.MalformedCompaction` for an
/// update with no id, which is the one field that says which compaction is
/// being reported.
pub fn parseCompaction(a: Allocator, update: rpc.Value) !Compaction {
    const id = rpc.str(update, "compactionId");
    if (id.len == 0 or id.len > max_id_bytes) return error.MalformedCompaction;
    var compaction: Compaction = .{ .id = &.{}, .status = .other, .reason = &.{} };
    errdefer deinitCompaction(&compaction, a);
    compaction.id = try a.dupe(u8, id);
    compaction.status = statusOf(rpc.str(update, "status"));
    compaction.reason = try limits.bounded(a, rpc.str(update, "error"), max_error_bytes);
    return compaction;
}

/// Release a compaction record, empties as it goes.
pub fn deinitCompaction(compaction: *Compaction, a: Allocator) void {
    if (compaction.id.len != 0) a.free(compaction.id);
    if (compaction.reason.len != 0) a.free(compaction.reason);
    compaction.* = .{ .id = &.{}, .status = .other, .reason = &.{} };
}

/// Read the commands an `available_commands_update` advertises. The list that
/// comes back belongs to `a` and is released with `freeCommands`.
///
/// Errors are `error.TooManyCommands` past `max_commands`; a list that long is
/// refused whole rather than cut, because half a menu is a menu that lies about
/// what an agent accepts.
pub fn parseCommands(a: Allocator, update: rpc.Value) ![]Command {
    const list = rpc.field(update, "availableCommands") orelse return &.{};
    if (list != .array) return &.{};
    if (list.array.items.len > max_commands) return error.TooManyCommands;
    var commands: std.ArrayList(Command) = .empty;
    errdefer {
        freeFields(a, commands.items);
        commands.deinit(a);
    }
    for (list.array.items) |item| {
        const name = rpc.str(item, "name");
        if (name.len == 0) continue;
        try commands.append(a, .{ .name = &.{}, .description = &.{}, .hint = &.{} });
        const command = &commands.items[commands.items.len - 1];
        // Every field of a command after its name is optional, and a field that
        // cannot be read is left empty rather than dropping the command: a
        // command a reader can pick is worth more than a tidy record.
        command.name = try limits.bounded(a, name, max_command_bytes);
        command.description = try limits.bounded(a, rpc.str(item, "description"), max_command_bytes);
        if (rpc.field(item, "input")) |input| {
            command.hint = try limits.bounded(a, rpc.str(input, "hint"), max_command_bytes);
        }
    }
    // The slice that goes back is the size of the menu, not the size of the
    // update: a caller releasing it must be releasing the allocation.
    return commands.toOwnedSlice(a);
}

/// Release a command list: every field of every command, and the slice they are
/// in. This is the counterpart of `parseCommands`, which hands back an
/// allocation of exactly the menu's size.
pub fn freeCommands(a: Allocator, commands: []Command) void {
    freeFields(a, commands);
    if (commands.len != 0) a.free(commands);
}

/// Release what each command owns, leaving the slice to whoever allocated it:
/// the list being built inside `parseCommands` grows, so its length is not its
/// capacity and only the container that allocated it may release it.
fn freeFields(a: Allocator, commands: []Command) void {
    for (commands) |command| {
        if (command.name.len != 0) a.free(command.name);
        if (command.description.len != 0) a.free(command.description);
        if (command.hint.len != 0) a.free(command.hint);
    }
}

/// The status a name stands for.
pub fn statusOf(text: []const u8) Status {
    if (std.ascii.eqlIgnoreCase(text, "in_progress") or std.ascii.eqlIgnoreCase(text, "in-progress")) return .in_progress;
    if (std.ascii.eqlIgnoreCase(text, "completed")) return .completed;
    if (std.ascii.eqlIgnoreCase(text, "failed")) return .failed;
    if (std.ascii.eqlIgnoreCase(text, "cancelled") or std.ascii.eqlIgnoreCase(text, "canceled")) return .cancelled;
    return .other;
}

/// A JSON number as a count. Both an integer and a float are numbers a session
/// may send for one of these, and neither is a string: `"42"` is not a count.
fn count(value: rpc.Value) ?u64 {
    return switch (value) {
        .integer => |n| if (n < 0) null else @intCast(n),
        .float => |x| if (x < 0 or x > 9_007_199_254_740_992) null else @intFromFloat(x),
        else => null,
    };
}

/// A JSON number as a number, for the cost of a session.
fn number(value: rpc.Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |x| x,
        else => null,
    };
}

fn readJson(a: Allocator, text: []const u8) !std.json.Parsed(rpc.Value) {
    return std.json.parseFromSlice(rpc.Value, a, text, .{ .allocate = .alloc_always });
}

test "a usage update says how full the context is and what it cost" {
    const a = std.testing.allocator;
    const full = try readJson(a,
        \\{"sessionUpdate":"usage_update","used":42000,"size":200000,"cost":{"amount":1.25,"currency":"USD"}}
    );
    defer full.deinit();
    var usage = try parseUsage(a, full.value);
    defer deinitUsage(&usage, a);
    try std.testing.expectEqual(@as(u64, 42000), usage.used);
    try std.testing.expectEqual(@as(u64, 200000), usage.size);
    try std.testing.expectEqual(@as(f64, 1.25), usage.cost.?.amount);
    try std.testing.expectEqualStrings("USD", usage.cost.?.currency);

    // A session that has spent nothing reports no cost, and the counts are
    // still the counts.
    const free = try readJson(a, "{\"sessionUpdate\":\"usage_update\",\"used\":0,\"size\":200000}");
    defer free.deinit();
    var none = try parseUsage(a, free.value);
    defer deinitUsage(&none, a);
    try std.testing.expectEqual(@as(u64, 0), none.used);
    try std.testing.expectEqual(@as(?Cost, null), none.cost);

    // Counts that are not counts are refused by name rather than stored as
    // zero, which would tell a reader the context is empty when it is not.
    const wrong = try readJson(a, "{\"sessionUpdate\":\"usage_update\",\"used\":\"lots\",\"size\":200000}");
    defer wrong.deinit();
    try std.testing.expectError(error.MalformedUsage, parseUsage(a, wrong.value));
    const missing = try readJson(a, "{\"sessionUpdate\":\"usage_update\",\"used\":10}");
    defer missing.deinit();
    try std.testing.expectError(error.MalformedUsage, parseUsage(a, missing.value));
}

test "a compaction names itself and says where it got to" {
    const a = std.testing.allocator;
    const failed = try readJson(a,
        \\{"sessionUpdate":"compaction_update","compactionId":"c1","status":"failed","error":"provider refused the summary"}
    );
    defer failed.deinit();
    var compaction = try parseCompaction(a, failed.value);
    defer deinitCompaction(&compaction, a);
    try std.testing.expectEqualStrings("c1", compaction.id);
    try std.testing.expectEqual(Status.failed, compaction.status);
    try std.testing.expectEqualStrings("provider refused the summary", compaction.reason);

    // A status this does not know is `other`: an agent's vocabulary will grow
    // before this reader does.
    const working = try readJson(a, "{\"sessionUpdate\":\"compaction_update\",\"compactionId\":\"c2\",\"status\":\"pondering\"}");
    defer working.deinit();
    var other = try parseCompaction(a, working.value);
    defer deinitCompaction(&other, a);
    try std.testing.expectEqual(Status.other, other.status);
    try std.testing.expectEqualStrings("", other.reason);
    try std.testing.expectEqual(Status.in_progress, statusOf("in_progress"));
    try std.testing.expectEqual(Status.cancelled, statusOf("canceled"));
    try std.testing.expectEqual(Status.completed, statusOf("completed"));

    // A compaction with no id is not one this can report on.
    const anonymous = try readJson(a, "{\"sessionUpdate\":\"compaction_update\",\"status\":\"in_progress\"}");
    defer anonymous.deinit();
    try std.testing.expectError(error.MalformedCompaction, parseCompaction(a, anonymous.value));
}

test "the command list is read whole or refused, and its fields are bounded" {
    const a = std.testing.allocator;
    const listed = try readJson(a,
        \\{"sessionUpdate":"available_commands_update","availableCommands":[
        \\ {"name":"create_plan","description":"Draft a plan","input":{"hint":"what to plan"}},
        \\ {"name":"research","description":"Look something up"}]}
    );
    defer listed.deinit();
    const commands = try parseCommands(a, listed.value);
    defer freeCommands(a, commands);
    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqualStrings("create_plan", commands[0].name);
    try std.testing.expectEqualStrings("Draft a plan", commands[0].description);
    try std.testing.expectEqualStrings("what to plan", commands[0].hint);
    // A command with no input wants nothing typed, which is not the same as one
    // whose input could not be read: both are empty, and both are pickable.
    try std.testing.expectEqualStrings("", commands[1].hint);

    // A command with no name is not a command, and a name is what a reader
    // types: it is dropped from the menu rather than shown blank.
    const nameless = try readJson(a,
        \\{"sessionUpdate":"available_commands_update","availableCommands":[{"description":"no name"},{"name":"real","description":"has a name"}]}
    );
    defer nameless.deinit();
    const kept = try parseCommands(a, nameless.value);
    defer freeCommands(a, kept);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("real", kept[0].name);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, "{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":[");
    for (0..max_commands + 1) |index| {
        if (index != 0) try wire.append(a, ',');
        try wire.appendSlice(a, "{\"name\":\"c\",\"description\":\"d\"}");
    }
    try wire.appendSlice(a, "]}");
    const many = try readJson(a, wire.items);
    defer many.deinit();
    try std.testing.expectError(error.TooManyCommands, parseCommands(a, many.value));
}
