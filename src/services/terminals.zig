//! The terminal dock's sessions.
//!
//! Each tab is a shell with its own emulator: a shell's state belongs to that
//! shell, and two tabs sharing one screen would be two views of one
//! conversation. The set owns them and knows which is showing. The interface
//! draws the strip and says what the reader asked for.
const std = @import("std");
const pty = @import("pty.zig");
const vt = @import("vt.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Session = struct {
    shell: pty.Pty,
    terminal: vt.Terminal,
    /// What the tab shows. Owned here, because a title outlives the frame that
    /// discovered it.
    title: []u8,
};

pub const Terminals = if (builtin.os.tag == .windows) Unsupported else Posix;

/// Where the selection lands after closing one tab.
///
/// Closing the last tab in the strip leaves the one before it selected, and
/// closing anything else leaves the selection where it was, because the tab
/// under the cursor should not move out from under it.
pub fn selectionAfterClose(count: usize, active: usize, closed: usize) usize {
    if (count == 0) return 0;
    const remaining = count - 1;
    if (remaining == 0) return 0;
    if (closed < active) return active - 1;
    if (closed > active) return active;
    return @min(active, remaining - 1);
}

/// The order of the sessions after moving one of them.
pub fn orderAfterMove(a: Allocator, count: usize, from: usize, to: usize) ![]usize {
    const order = try a.alloc(usize, count);
    for (order, 0..) |*slot, index| slot.* = index;
    if (from >= count or to >= count or from == to) return order;
    const moved = order[from];
    if (from < to) {
        std.mem.copyForwards(usize, order[from..to], order[from + 1 .. to + 1]);
    } else {
        std.mem.copyBackwards(usize, order[to + 1 .. from + 1], order[to..from]);
    }
    order[to] = moved;
    return order;
}

const Unsupported = struct {
    allocator: Allocator,
    active: usize = 0,

    pub fn init(a: Allocator) Unsupported {
        return .{ .allocator = a };
    }

    pub fn deinit(_: *Unsupported) void {}

    pub fn spawn(_: *Unsupported, _: []const []const u8, _: u16, _: u16, _: []const u8) !usize {
        return error.PtyUnsupported;
    }

    pub fn close(_: *Unsupported, _: usize) void {}

    pub fn resizeActive(_: *Unsupported, _: u16, _: u16) void {}

    pub fn move(_: *Unsupported, _: usize, _: usize) void {}

    pub fn select(_: *Unsupported, _: usize) void {}

    pub fn count(_: *const Unsupported) usize {
        return 0;
    }

    pub fn titleAt(_: *const Unsupported, _: usize) ?[]const u8 {
        return null;
    }

    pub fn setTitle(_: *Unsupported, _: usize, _: []const u8) !void {}

    pub fn activeSession(_: *Unsupported) ?*Session {
        return null;
    }
};

const Posix = struct {
    allocator: Allocator,
    sessions: std.ArrayList(Session) = .empty,
    active: usize = 0,

    pub fn init(a: Allocator) Posix {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Posix) void {
        for (self.sessions.items) |*session| {
            // The shell is killed and reaped before the emulator that read it.
            session.shell.deinit();
            session.terminal.deinit();
            self.allocator.free(session.title);
        }
        self.sessions.deinit(self.allocator);
    }

    /// Add a session and make it the one showing, which is what opening a tab
    /// means.
    pub fn spawn(self: *Posix, argv: []const []const u8, cols: u16, rows: u16, title: []const u8) !usize {
        var shell = try pty.Pty.spawn(self.allocator, argv, cols, rows);
        errdefer shell.deinit();
        var terminal = try vt.Terminal.init(self.allocator, cols, rows);
        errdefer terminal.deinit();
        try self.sessions.append(self.allocator, .{
            .shell = shell,
            .terminal = terminal,
            .title = try self.allocator.dupe(u8, title),
        });
        self.active = self.sessions.items.len - 1;
        return self.active;
    }

    pub fn close(self: *Posix, index: usize) void {
        if (index >= self.sessions.items.len) return;
        var removed = self.sessions.orderedRemove(index);
        removed.shell.deinit();
        removed.terminal.deinit();
        self.allocator.free(removed.title);
        self.active = selectionAfterClose(self.sessions.items.len + 1, self.active, index);
    }

    pub fn move(self: *Posix, from: usize, to: usize) void {
        if (from >= self.sessions.items.len or to >= self.sessions.items.len or from == to) return;
        const moved = self.sessions.orderedRemove(from);
        self.sessions.insert(self.allocator, to, moved) catch return;
        // The selection follows the tab it was on, not the position it was in.
        self.active = to;
    }

    pub fn select(self: *Posix, index: usize) void {
        if (index < self.sessions.items.len) self.active = index;
    }

    pub fn count(self: *const Posix) usize {
        return self.sessions.items.len;
    }

    pub fn activeSession(self: *Posix) ?*Session {
        if (self.sessions.items.len == 0) return null;
        if (self.active >= self.sessions.items.len) self.active = self.sessions.items.len - 1;
        return &self.sessions.items[self.active];
    }

    /// Keep the shell's idea of the terminal the same as the dock's.
    pub fn resizeActive(self: *Posix, cols: u16, rows: u16) void {
        const session = self.activeSession() orelse return;
        session.shell.resize(cols, rows);
    }

    pub fn titleAt(self: *const Posix, index: usize) ?[]const u8 {
        if (index >= self.sessions.items.len) return null;
        return self.sessions.items[index].title;
    }

    pub fn setTitle(self: *Posix, index: usize, title: []const u8) !void {
        if (index >= self.sessions.items.len) return;
        const owned = try self.allocator.dupe(u8, title);
        self.allocator.free(self.sessions.items[index].title);
        self.sessions.items[index].title = owned;
    }
};

test "closing a tab leaves the reader looking at the one that should be there" {
    // Closing a tab after the selection leaves it alone.
    try std.testing.expectEqual(@as(usize, 1), selectionAfterClose(3, 1, 2));
    // Closing one before it moves the selection with the tab it was on.
    try std.testing.expectEqual(@as(usize, 0), selectionAfterClose(3, 1, 0));
    // Closing the selected tab lands on the one before it.
    try std.testing.expectEqual(@as(usize, 1), selectionAfterClose(3, 2, 2));
    // Closing the last tab there is leaves nothing to select.
    try std.testing.expectEqual(@as(usize, 0), selectionAfterClose(1, 0, 0));
}

test "moving a tab keeps every other tab's order" {
    const a = std.testing.allocator;
    const forward = try orderAfterMove(a, 4, 1, 3);
    defer a.free(forward);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3, 1 }, forward);

    const backward = try orderAfterMove(a, 4, 3, 1);
    defer a.free(backward);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 1, 2 }, backward);

    // A move that goes nowhere changes nothing, which is what a click that is
    // not a drag has to mean.
    const still = try orderAfterMove(a, 3, 1, 1);
    defer a.free(still);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, still);
}
