//! A plan, read out of the updates an agent sends to say what it is about to
//! do.
//!
//! An agent reports a plan as tasks with a state each and then moves through
//! them: `plan` sends the whole plan, `plan_update` sends one plan's new body,
//! `plan_removed` takes a plan away. None of that is prose, so none of it goes
//! into the transcript - what used to go there was the update's JSON, which is
//! the same sin as showing a reader `{"toolCallId":...}`. A plan is a list a
//! reader watches move, so it is kept as one: entries with a status and a
//! priority each, or the markdown or file an agent keeps its plan in.
//!
//! Every field is bounded and every list is bounded, in the same style as
//! `tool_call.zig`: a plan that carries more tasks than `max_entries`, or a
//! body past `max_body_bytes`, is refused by name rather than stored.

const std = @import("std");
const rpc = @import("protocol.zig");
const limits = @import("limits.zig");
const Allocator = std.mem.Allocator;

/// Where one task of a plan has got to. The vocabulary has three states, and a
/// state this does not know is `other` rather than a guess: a task the agent
/// has not started and one it is doing something else with are not the same.
pub const Status = enum { pending, in_progress, completed, other };

/// How much a task matters: what a reader sorts a plan by.
pub const Priority = enum { high, medium, low, other };

/// One task: what it is, and where it has got to.
pub const Entry = struct { content: []const u8, priority: Priority, status: Status };

/// What a plan is made of. Agents report plans three ways, and the client keeps
/// whichever one arrived.
pub const Body = union(enum) {
    /// A list of tasks.
    entries: []const Entry,
    /// Raw markdown.
    markdown: []const u8,
    /// The URI of the file the agent keeps the plan in. A plan too large to
    /// send is a plan a client is told where to read.
    file: []const u8,
};

/// One plan, as the interface draws it.
pub const Plan = struct {
    /// The agent's id for the plan. The older `plan` update carries no id, and
    /// the plan it describes is the session's one anonymous plan: `""`.
    id: []const u8,
    body: Body,
};

/// The most plans one session may hold at once. Plans are removed by the agent
/// and dropped when this is reached, oldest first.
pub const max_plans: usize = 16;

/// The most tasks one plan may carry. Every update to a plan replaces it whole,
/// so a plan past this is not a plan a reader can use; it is refused rather
/// than stored.
pub const max_entries: usize = 128;

/// The most bytes one task's description may take.
pub const max_entry_bytes: usize = 256;

/// The most bytes a markdown plan or a file URI may take.
pub const max_body_bytes: usize = 16 * 1024;

/// The most bytes a plan id may take. An id is an opaque name, not content.
pub const max_plan_id_bytes: usize = 128;

/// Apply one `plan`, `plan_update` or `plan_removed` to `plans`.
///
/// A plan is identified by its id, so an update to a plan the list already
/// holds replaces that plan's body in place - the order a reader sees does not
/// shuffle because an agent sent a task list twice. `plan_removed` takes one
/// away, and an id this has not seen is nothing to remove.
///
/// Errors are `error.MalformedPlan` for an update that is not the object this
/// reads, `error.TooManyEntries` past `max_entries`, and `error.PlanTooLarge`
/// past `max_body_bytes`. On failure nothing has changed.
pub fn apply(plans: *std.ArrayList(Plan), a: Allocator, update: rpc.Value) !void {
    const kind = rpc.str(update, "sessionUpdate");
    if (std.mem.eql(u8, kind, "plan_removed")) {
        remove(plans, a, rpc.str(update, "planId"));
        return;
    }
    if (std.mem.eql(u8, kind, "plan")) {
        // The whole plan, with no id: the anonymous one.
        return put(plans, a, "", try readEntries(a, rpc.field(update, "entries") orelse return error.MalformedPlan));
    }
    if (!std.mem.eql(u8, kind, "plan_update")) return error.MalformedPlan;
    const content = rpc.field(update, "plan") orelse return error.MalformedPlan;
    if (content != .object) return error.MalformedPlan;
    const id = rpc.str(content, "planId");
    if (id.len == 0 or id.len > max_plan_id_bytes) return error.MalformedPlan;
    const form = rpc.str(content, "type");
    if (std.mem.eql(u8, form, "items")) {
        return put(plans, a, id, try readEntries(a, rpc.field(content, "entries") orelse return error.MalformedPlan));
    }
    // A body past the bound is refused whole rather than stored in part: a plan
    // is a list to work from, and half a plan is not one.
    if (std.mem.eql(u8, form, "markdown")) {
        const text = rpc.str(content, "content");
        if (text.len > max_body_bytes) return error.PlanTooLarge;
        return put(plans, a, id, .{ .markdown = try a.dupe(u8, text) });
    }
    if (std.mem.eql(u8, form, "file")) {
        const uri = rpc.str(content, "uri");
        if (uri.len > max_body_bytes) return error.PlanTooLarge;
        return put(plans, a, id, .{ .file = try a.dupe(u8, uri) });
    }
    // A plan in a form this does not read is refused rather than stored as the
    // JSON it arrived as.
    return error.MalformedPlan;
}

/// Store `body` as the plan with this id, replacing what that plan held.
fn put(plans: *std.ArrayList(Plan), a: Allocator, id: []const u8, body: Body) !void {
    const owned_id = try a.dupe(u8, id);
    errdefer a.free(owned_id);
    var next: Plan = .{ .id = owned_id, .body = body };
    errdefer deinit(&next, a);
    for (plans.items) |*stored| {
        if (!std.mem.eql(u8, stored.id, id)) continue;
        // Everything of the old plan goes, and the new one takes its place: a
        // plan is replaced whole, which is what the protocol says an update is.
        deinit(stored, a);
        stored.* = next;
        return;
    }
    try plans.append(a, next);
    if (plans.items.len > max_plans) {
        var oldest = plans.orderedRemove(0);
        deinit(&oldest, a);
    }
}

/// Take a plan away. An id the list does not hold is nothing to remove, because
/// a client that joined a session late never saw the plan that is being
/// removed.
pub fn remove(plans: *std.ArrayList(Plan), a: Allocator, id: []const u8) void {
    for (plans.items, 0..) |plan, index| {
        if (!std.mem.eql(u8, plan.id, id)) continue;
        var gone = plans.orderedRemove(index);
        deinit(&gone, a);
        return;
    }
}

/// Read a plan's task list, bounded. Everything returned belongs to `a`.
fn readEntries(a: Allocator, value: rpc.Value) !Body {
    if (value != .array) return error.MalformedPlan;
    if (value.array.items.len > max_entries) return error.TooManyEntries;
    const entries = try a.alloc(Entry, value.array.items.len);
    var done: usize = 0;
    errdefer {
        for (entries[0..done]) |entry| a.free(entry.content);
        a.free(entries);
    }
    for (value.array.items, 0..) |item, index| {
        const content = rpc.str(item, "content");
        if (content.len == 0) return error.MalformedPlan;
        entries[index] = .{
            .content = try limits.bounded(a, content, max_entry_bytes),
            .priority = priorityOf(rpc.str(item, "priority")),
            .status = statusOf(rpc.str(item, "status")),
        };
        done = index + 1;
    }
    return .{ .entries = entries };
}

/// The state a status names. A status this does not recognise is `other`, not
/// `pending`: a task whose state is unreadable has not necessarily not started.
pub fn statusOf(text: []const u8) Status {
    if (std.ascii.eqlIgnoreCase(text, "pending")) return .pending;
    if (std.ascii.eqlIgnoreCase(text, "in_progress") or std.ascii.eqlIgnoreCase(text, "in-progress")) return .in_progress;
    if (std.ascii.eqlIgnoreCase(text, "completed")) return .completed;
    return .other;
}

/// The importance a priority names, which is the same vocabulary read one word
/// at a time.
pub fn priorityOf(text: []const u8) Priority {
    if (std.ascii.eqlIgnoreCase(text, "high")) return .high;
    if (std.ascii.eqlIgnoreCase(text, "medium")) return .medium;
    if (std.ascii.eqlIgnoreCase(text, "low")) return .low;
    return .other;
}

/// Release a plan: its id, its tasks, and its body, whichever form it took. The
/// plan is emptied as it goes, so releasing one twice is a no-op rather than a
/// fault.
pub fn deinit(plan: *Plan, a: Allocator) void {
    if (plan.id.len != 0) a.free(plan.id);
    switch (plan.body) {
        .entries => |entries| {
            for (entries) |entry| {
                if (entry.content.len != 0) a.free(entry.content);
            }
            if (entries.len != 0) a.free(entries);
        },
        .markdown => |text| {
            if (text.len != 0) a.free(text);
        },
        .file => |uri| {
            if (uri.len != 0) a.free(uri);
        },
    }
    plan.* = .{ .id = &.{}, .body = .{ .entries = &.{} } };
}

test "a plan arrives whole, updates itself, and is removed by id" {
    const a = std.testing.allocator;
    var plans: std.ArrayList(Plan) = .empty;
    defer {
        for (plans.items) |*plan| deinit(plan, a);
        plans.deinit(a);
    }

    // The whole plan, as the update without an id sends it.
    const plan = try readJson(a,
        \\{"sessionUpdate":"plan","entries":[
        \\  {"content":"read the transcript widget","priority":"high","status":"in_progress"},
        \\  {"content":"draw thoughts","priority":"medium","status":"pending"}]}
    );
    defer plan.deinit();
    try apply(&plans, a, plan.value);
    try std.testing.expectEqual(@as(usize, 1), plans.items.len);
    try std.testing.expectEqualStrings("", plans.items[0].id);
    try std.testing.expectEqual(@as(usize, 2), plans.items[0].body.entries.len);
    try std.testing.expectEqualStrings("read the transcript widget", plans.items[0].body.entries[0].content);
    try std.testing.expectEqual(Priority.high, plans.items[0].body.entries[0].priority);
    try std.testing.expectEqual(Status.in_progress, plans.items[0].body.entries[0].status);
    try std.testing.expectEqual(Status.pending, plans.items[0].body.entries[1].status);

    // A named plan is a plan of its own: an agent working two of them does not
    // have one overwrite the other.
    const named = try readJson(a,
        \\{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p1","entries":[
        \\  {"content":"fix the offset","priority":"low","status":"completed"}]}}
    );
    defer named.deinit();
    try apply(&plans, a, named.value);
    try std.testing.expectEqual(@as(usize, 2), plans.items.len);
    try std.testing.expectEqualStrings("p1", plans.items[1].id);
    try std.testing.expectEqual(Status.completed, plans.items[1].body.entries[0].status);

    // Updating an existing plan replaces it where it stands rather than moving
    // it to the end: the order of a reader's plans is not the order of updates.
    const again = try readJson(a,
        \\{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p1","entries":[
        \\  {"content":"fix the offset","priority":"low","status":"completed"},
        \\  {"content":"and the trim","priority":"high","status":"in_progress"}]}}
    );
    defer again.deinit();
    try apply(&plans, a, again.value);
    try std.testing.expectEqual(@as(usize, 2), plans.items.len);
    try std.testing.expectEqualStrings("p1", plans.items[1].id);
    try std.testing.expectEqual(@as(usize, 2), plans.items[1].body.entries.len);

    // A plan an agent keeps as markdown, and one it keeps in a file, are both
    // plans: the body is whichever form arrived.
    const markdown = try readJson(a,
        \\{"sessionUpdate":"plan_update","plan":{"type":"markdown","planId":"p2","content":"1. look\n2. draw"}}
    );
    defer markdown.deinit();
    try apply(&plans, a, markdown.value);
    try std.testing.expectEqualStrings("1. look\n2. draw", plans.items[2].body.markdown);
    const file = try readJson(a,
        \\{"sessionUpdate":"plan_update","plan":{"type":"file","planId":"p3","uri":"file:///tmp/plan.md"}}
    );
    defer file.deinit();
    try apply(&plans, a, file.value);
    try std.testing.expectEqualStrings("file:///tmp/plan.md", plans.items[3].body.file);

    // Removing one takes that one, leaving the rest where they were.
    const gone = try readJson(a,
        \\{"sessionUpdate":"plan_removed","planId":"p1"}
    );
    defer gone.deinit();
    try apply(&plans, a, gone.value);
    try std.testing.expectEqual(@as(usize, 3), plans.items.len);
    try std.testing.expectEqualStrings("", plans.items[0].id);
    try std.testing.expectEqualStrings("p2", plans.items[1].id);
    // Removing a plan that is not there is nothing to remove, not an error.
    try apply(&plans, a, gone.value);
    try std.testing.expectEqual(@as(usize, 3), plans.items.len);
}

test "a plan too large or in an unknown form is refused by name, and leaves the list alone" {
    const a = std.testing.allocator;
    var plans: std.ArrayList(Plan) = .empty;
    defer {
        for (plans.items) |*plan| deinit(plan, a);
        plans.deinit(a);
    }

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, "{\"sessionUpdate\":\"plan\",\"entries\":[");
    for (0..max_entries + 1) |index| {
        if (index != 0) try wire.append(a, ',');
        try wire.appendSlice(a, "{\"content\":\"a task\",\"priority\":\"low\",\"status\":\"pending\"}");
    }
    try wire.appendSlice(a, "]}");
    const many = try std.json.parseFromSlice(rpc.Value, a, wire.items, .{});
    defer many.deinit();
    try std.testing.expectError(error.TooManyEntries, apply(&plans, a, many.value));
    try std.testing.expectEqual(@as(usize, 0), plans.items.len);

    // A task with no words is not a task, and a plan that is half read tasks is
    // worse than no plan.
    const nameless = try readJson(a,
        \\{"sessionUpdate":"plan","entries":[{"priority":"low","status":"pending"}]}
    );
    defer nameless.deinit();
    try std.testing.expectError(error.MalformedPlan, apply(&plans, a, nameless.value));

    // A body past the bound is refused rather than cut: a plan is a list to
    // work from, and half a plan is not one.
    const big = try a.alloc(u8, max_body_bytes + 1);
    defer a.free(big);
    @memset(big, 'm');
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(a);
    try object.put(a, "type", .{ .string = "markdown" });
    try object.put(a, "planId", .{ .string = "p1" });
    try object.put(a, "content", .{ .string = big });
    var update: std.json.ObjectMap = .empty;
    defer update.deinit(a);
    try update.put(a, "sessionUpdate", .{ .string = "plan_update" });
    try update.put(a, "plan", .{ .object = object });
    try std.testing.expectError(error.PlanTooLarge, apply(&plans, a, .{ .object = update }));

    // A form this does not read is refused, not stored as the JSON it came in.
    const unknown = try readJson(a,
        \\{"sessionUpdate":"plan_update","plan":{"type":"hologram","planId":"p1"}}
    );
    defer unknown.deinit();
    try std.testing.expectError(error.MalformedPlan, apply(&plans, a, unknown.value));
    try std.testing.expectEqual(@as(usize, 0), plans.items.len);
}

fn readJson(a: Allocator, text: []const u8) !std.json.Parsed(rpc.Value) {
    return std.json.parseFromSlice(rpc.Value, a, text, .{ .allocate = .alloc_always });
}
