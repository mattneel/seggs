//! Which runs the reader has opened.
//!
//! A call's expansion is keyed by the agent's id for it, which the protocol
//! gives. A run has no such id - a thought is anonymous and a compaction's id
//! is shared by every run of that compaction - so this keys on the run's
//! sequence number, which the client hands out as the run begins. That is the
//! one thing about a run that neither the text arriving nor the transcript
//! trimming its front changes, and both of those move everything else: a fold
//! keyed on the offset would reopen a different run the moment the transcript
//! dropped a kilobyte.
//!
//! A run with no answer is shut. That is the whole reason the runs exist as a
//! separate kind of thing: shut, a run of reasoning is one line that says it
//! happened, and the reader who wants the words opens it.

const std = @import("std");
const acp = @import("../acp/stream.zig");
const Allocator = std.mem.Allocator;

/// One answer the reader gave: this run, in this lane, open or shut.
pub const Fold = struct { lane: usize, seq: usize, open: bool };

pub const Folds = struct {
    /// Small: a reader opens a handful of runs in a session, and an entry whose
    /// run has left the transcript is dropped rather than kept.
    items: std.ArrayList(Fold) = .empty,
    allocator: Allocator,

    pub fn init(a: Allocator) Folds {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Folds) void {
        self.items.deinit(self.allocator);
        self.items = .empty;
    }

    /// Whether this run is open. A run nobody has answered about is shut.
    pub fn isOpen(self: *const Folds, lane: usize, seq: usize) bool {
        for (self.items.items) |fold| {
            if (fold.lane == lane and fold.seq == seq) return fold.open;
        }
        return false;
    }

    /// Open a shut run, or shut an open one.
    pub fn toggle(self: *Folds, lane: usize, seq: usize) !void {
        for (self.items.items) |*fold| {
            if (fold.lane != lane or fold.seq != seq) continue;
            fold.open = !fold.open;
            return;
        }
        try self.items.append(self.allocator, .{ .lane = lane, .seq = seq, .open = true });
    }

    /// Forget every answer, so every run follows the default again. This is what
    /// a key that opens or shuts the whole transcript calls: the per-run answers
    /// are dropped rather than left to fight it.
    pub fn clear(self: *Folds) void {
        self.items.clearRetainingCapacity();
    }

    /// Forget the answers about runs this lane no longer keeps. A run that has
    /// left the transcript - the oldest of them go when the list is full - has
    /// nothing left to open, so the answer about it goes with it, and the
    /// sequence numbers are never reused so a stale answer can never land on a
    /// different run.
    pub fn prune(self: *Folds, lane: usize, live: []const acp.Stream) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            const fold = self.items.items[index];
            if (fold.lane == lane and !kept(live, fold.seq)) {
                _ = self.items.swapRemove(index);
                continue;
            }
            index += 1;
        }
    }

    fn kept(live: []const acp.Stream, seq: usize) bool {
        for (live) |record| {
            if (record.seq == seq) return true;
        }
        return false;
    }
};

test "a run is shut until the reader opens it, and the answer is per run" {
    const a = std.testing.allocator;
    var folds = Folds.init(a);
    defer folds.deinit();

    try std.testing.expect(!folds.isOpen(0, 4));
    try folds.toggle(0, 4);
    try std.testing.expect(folds.isOpen(0, 4));
    // Another run is another answer, and so is another lane's run with the same
    // number: two lanes number their runs from their own counters.
    try std.testing.expect(!folds.isOpen(0, 5));
    try std.testing.expect(!folds.isOpen(1, 4));
    try folds.toggle(0, 4);
    try std.testing.expect(!folds.isOpen(0, 4));
    try std.testing.expectEqual(@as(usize, 1), folds.items.items.len);
}

test "an answer about a run that is gone goes with it" {
    const a = std.testing.allocator;
    var folds = Folds.init(a);
    defer folds.deinit();

    try folds.toggle(0, 1);
    try folds.toggle(0, 2);
    try folds.toggle(1, 2);
    // The transcript keeps one run, so the answers about the others are dropped
    // and the one that is still there keeps its answer.
    var live = [_]acp.Stream{try acp.begin(a, .thought, "", 0, 2)};
    defer acp.deinit(&live[0], a);
    folds.prune(0, &live);
    try std.testing.expect(!folds.isOpen(0, 1));
    try std.testing.expect(folds.isOpen(0, 2));
    // Another lane's answers are its own: a lane that still keeps its runs is
    // not pruned by a lane that does not.
    try std.testing.expect(folds.isOpen(1, 2));

    // A key that opens or shuts everything drops every answer rather than
    // leaving them to fight the new default.
    folds.clear();
    try std.testing.expect(!folds.isOpen(0, 2));
    try std.testing.expectEqual(@as(usize, 0), folds.items.items.len);
}
