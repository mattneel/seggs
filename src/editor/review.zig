const std = @import("std");
const Document = @import("document.zig").Document;
const contracts = @import("../services/contracts.zig");
const Allocator = std.mem.Allocator;

pub const Outcome = enum { applied, conflict, invalid };

/// The text an edit would remove and insert, for review before apply.
pub const Preview = struct { removed: []u8, inserted: []u8 };

/// Holds agent-proposed edits until they apply against a matching document
/// revision. Pure logic that owns its strings; the caller maps paths to
/// documents.
pub const ReviewQueue = struct {
    allocator: Allocator,
    edits: std.ArrayList(contracts.ProposedEdit) = .empty,

    pub fn init(a: Allocator) ReviewQueue {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *ReviewQueue) void {
        for (self.edits.items) |edit| self.freeEdit(edit);
        self.edits.deinit(self.allocator);
    }

    fn freeEdit(self: *ReviewQueue, edit: contracts.ProposedEdit) void {
        self.allocator.free(edit.path);
        self.allocator.free(edit.replacement);
    }

    pub fn count(self: *const ReviewQueue) usize {
        return self.edits.items.len;
    }

    pub fn editAt(self: *const ReviewQueue, index: usize) contracts.ProposedEdit {
        return self.edits.items[index];
    }

    /// Own a copy of a proposed edit.
    pub fn propose(self: *ReviewQueue, edit: contracts.ProposedEdit) !void {
        const path = try self.allocator.dupe(u8, edit.path);
        errdefer self.allocator.free(path);
        const replacement = try self.allocator.dupe(u8, edit.replacement);
        errdefer self.allocator.free(replacement);
        try self.edits.append(self.allocator, .{
            .path = path,
            .expected_revision = edit.expected_revision,
            .start_byte = edit.start_byte,
            .end_byte = edit.end_byte,
            .replacement = replacement,
        });
    }

    /// Apply an edit to a document only when the revision it expected is still
    /// current. A successful apply removes the edit from the queue.
    pub fn apply(self: *ReviewQueue, index: usize, document: *Document) !Outcome {
        const edit = self.edits.items[index];
        if (edit.expected_revision != document.revision) return .conflict;
        document.replace(edit.start_byte, edit.end_byte, edit.replacement) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .invalid,
        };
        self.freeEdit(self.edits.orderedRemove(index));
        return .applied;
    }

    /// The removed and inserted text for a queued edit. The caller owns both.
    /// Drop a proposed change. Rejecting is a decision like accepting: the
    /// queue is what a person is being asked about, and answering is either.
    pub fn discard(self: *ReviewQueue, index: usize) void {
        if (index >= self.edits.items.len) return;
        // The queue owns the strings it was given, so dropping an edit drops
        // them with it.
        self.freeEdit(self.edits.orderedRemove(index));
    }

    pub fn preview(self: *const ReviewQueue, index: usize, document: *const Document, a: Allocator) !Preview {
        const edit = self.edits.items[index];
        const bytes = try document.snapshot(a);
        defer a.free(bytes);
        const removed = try a.dupe(u8, bytes[edit.start_byte..edit.end_byte]);
        errdefer a.free(removed);
        const inserted = try a.dupe(u8, edit.replacement);
        return .{ .removed = removed, .inserted = inserted };
    }
};

test "applies an edit only at the matching revision" {
    var queue = ReviewQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.propose(.{ .path = "a.zig", .expected_revision = 0, .start_byte = 0, .end_byte = 5, .replacement = "hi" });
    var doc = try Document.init(std.testing.allocator, "hello");
    defer doc.deinit();
    try std.testing.expectEqual(Outcome.applied, try queue.apply(0, &doc));
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    const bytes = try doc.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("hi", bytes);
}

test "rejects a stale revision and keeps the edit" {
    var queue = ReviewQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.propose(.{ .path = "a.zig", .expected_revision = 0, .start_byte = 0, .end_byte = 1, .replacement = "X" });
    var doc = try Document.init(std.testing.allocator, "hello");
    defer doc.deinit();
    try doc.insert("!");
    try std.testing.expectEqual(Outcome.conflict, try queue.apply(0, &doc));
    try std.testing.expectEqual(@as(usize, 1), queue.count());
}

test "reports an edit whose range is no longer valid" {
    var queue = ReviewQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.propose(.{ .path = "a.zig", .expected_revision = 0, .start_byte = 2, .end_byte = 3, .replacement = "x" });
    var doc = try Document.init(std.testing.allocator, "a\xc3\xa9");
    defer doc.deinit();
    try std.testing.expectEqual(Outcome.invalid, try queue.apply(0, &doc));
    try std.testing.expectEqual(@as(usize, 1), queue.count());
}

test "preview shows the removed and inserted text" {
    var queue = ReviewQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.propose(.{ .path = "a.zig", .expected_revision = 0, .start_byte = 0, .end_byte = 5, .replacement = "hi" });
    var doc = try Document.init(std.testing.allocator, "hello");
    defer doc.deinit();
    const p = try queue.preview(0, &doc, std.testing.allocator);
    defer std.testing.allocator.free(p.removed);
    defer std.testing.allocator.free(p.inserted);
    try std.testing.expectEqualStrings("hello", p.removed);
    try std.testing.expectEqualStrings("hi", p.inserted);
}
