const std = @import("std");
const Document = @import("document.zig").Document;
const review = @import("review.zig");
const files = @import("../platform/files.zig");
const Allocator = std.mem.Allocator;

/// One open document and its on-disk identity.
pub const Buffer = struct {
    document: Document,
    path: ?[]u8 = null,
    baseline: ?[]u8 = null,
    stamp: ?files.FileStamp = null,
    saved_revision: u64 = 0,

    fn dirty(self: *const Buffer) bool {
        return self.document.revision != self.saved_revision;
    }

    fn name(self: *const Buffer) []const u8 {
        return if (self.path) |path| std.fs.path.basename(path) else "Welcome.zig";
    }

    fn deinit(self: *Buffer, a: Allocator) void {
        self.document.deinit();
        if (self.path) |path| a.free(path);
        if (self.baseline) |bytes| a.free(bytes);
        self.* = undefined;
    }
};

pub const Workspace = struct {
    allocator: Allocator,
    root: []const u8,
    buffers: std.ArrayList(Buffer) = .empty,
    active: usize = 0,
    explorer: files.Explorer,

    pub const welcome =
        "// Seggs / agent-native workspace\n" ++
        "// Open a file from the explorer or press Ctrl+P.\n" ++
        "// Ctrl+L focuses the agent prompt. F11 toggles fullscreen.\n\n" ++
        "const std = @import(\"std\");\n\n" ++
        "pub fn main() void {\n" ++
        "    std.log.info(\"Think together. Build in parallel.\", .{});\n" ++
        "}\n\n" ++
        "// Oh-My-Pi: omp acp\n" ++
        "// Codex: codex-acp\n" ++
        "// Claude Code: claude-agent-acp\n" ++
        "// Each agent owns an independent ACP session.\n";

    pub fn init(a: Allocator, root: []const u8) !Workspace {
        var explorer = try files.Explorer.init(a, root);
        errdefer explorer.deinit();
        var buffers: std.ArrayList(Buffer) = .empty;
        errdefer {
            for (buffers.items) |*buffer| buffer.deinit(a);
            buffers.deinit(a);
        }
        var document = try Document.init(a, welcome);
        errdefer document.deinit();
        try buffers.append(a, .{ .document = document });
        return .{ .allocator = a, .root = root, .buffers = buffers, .active = 0, .explorer = explorer };
    }

    pub fn deinit(self: *Workspace) void {
        for (self.buffers.items) |*buffer| buffer.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.explorer.deinit();
    }

    pub fn activeDocument(self: *Workspace) *Document {
        return &self.buffers.items[self.active].document;
    }

    pub fn activePath(self: *const Workspace) ?[]const u8 {
        return self.buffers.items[self.active].path;
    }

    pub fn activeIndex(self: *const Workspace) usize {
        return self.active;
    }

    pub fn bufferCount(self: *const Workspace) usize {
        return self.buffers.items.len;
    }

    pub fn bufferName(self: *const Workspace, i: usize) []const u8 {
        return self.buffers.items[i].name();
    }

    pub fn bufferDirty(self: *const Workspace, i: usize) bool {
        return self.buffers.items[i].dirty();
    }

    pub fn switchTo(self: *Workspace, i: usize) void {
        self.active = @min(i, self.buffers.items.len - 1);
    }

    pub fn cycle(self: *Workspace, forward: bool) void {
        const n = self.buffers.items.len;
        if (n < 2) return;
        self.active = if (forward) (self.active + 1) % n else (self.active + n - 1) % n;
    }

    pub fn dirty(self: *const Workspace) bool {
        return self.buffers.items[self.active].dirty();
    }

    /// Switch to an already-open buffer, or open and append a new one.
    /// Opening never discards the active document, so no unsaved-change gate.
    pub fn open(self: *Workspace, path: []const u8) !void {
        for (self.buffers.items, 0..) |*buffer, i| {
            if (buffer.path) |existing| {
                if (std.mem.eql(u8, existing, path)) {
                    self.active = i;
                    return;
                }
            }
        }
        const bytes = try files.read(self.allocator, path, Document.max_bytes);
        errdefer self.allocator.free(bytes);
        var document = try Document.init(self.allocator, bytes);
        errdefer document.deinit();
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const saved_stamp = try files.stamp(self.allocator, path);
        try self.buffers.append(self.allocator, .{
            .document = document,
            .path = owned_path,
            .baseline = bytes,
            .stamp = saved_stamp,
            .saved_revision = 0,
        });
        self.active = self.buffers.items.len - 1;
    }

    pub fn save(self: *Workspace) !void {
        const buffer = &self.buffers.items[self.active];
        const path = buffer.path orelse return error.OpenAFileBeforeSave;
        const disk = try files.read(self.allocator, path, Document.max_bytes);
        defer self.allocator.free(disk);
        if (!std.mem.eql(u8, disk, buffer.baseline.?)) return error.ExternalChangeConflict;
        const bytes = try buffer.document.snapshot(self.allocator);
        errdefer self.allocator.free(bytes);
        try files.replace(self.allocator, path, bytes);
        self.allocator.free(buffer.baseline.?);
        buffer.baseline = bytes;
        buffer.saved_revision = buffer.document.revision;
        buffer.stamp = files.stamp(self.allocator, path) catch null;
    }

    /// True when the on-disk file differs from the last loaded or saved stamp.
    /// A file that can no longer be read counts as changed.
    pub fn externalChanged(self: *const Workspace, i: usize) bool {
        const buffer = &self.buffers.items[i];
        const path = buffer.path orelse return false;
        const current = files.stamp(self.allocator, path) catch return true;
        if (buffer.stamp) |saved| return !saved.eql(current);
        return false;
    }

    /// Re-read the active file from disk, discarding its in-memory baseline.
    /// Refuses while the buffer has unsaved changes.
    pub fn reload(self: *Workspace) !void {
        const buffer = &self.buffers.items[self.active];
        const path = buffer.path orelse return error.OpenAFileBeforeSave;
        if (buffer.dirty()) return error.UnsavedChanges;
        const bytes = try files.read(self.allocator, path, Document.max_bytes);
        errdefer self.allocator.free(bytes);
        var document = try Document.init(self.allocator, bytes);
        errdefer document.deinit();
        const saved_stamp = try files.stamp(self.allocator, path);
        buffer.document.deinit();
        buffer.document = document;
        self.allocator.free(buffer.baseline.?);
        buffer.baseline = bytes;
        buffer.stamp = saved_stamp;
        buffer.saved_revision = 0;
    }

    pub fn findBuffer(self: *const Workspace, path: []const u8) ?usize {
        for (self.buffers.items, 0..) |*buffer, i| {
            if (buffer.path) |p| {
                if (std.mem.eql(u8, p, path)) return i;
            }
        }
        return null;
    }

    /// Whether the buffer named by `path` is open and still at `revision`.
    /// Null means the file is not open, which is a different answer from a
    /// buffer that has moved on.
    pub fn bufferMatches(self: *const Workspace, path: []const u8, revision: u64) ?bool {
        const index = self.findBuffer(path) orelse return null;
        return self.buffers.items[index].document.revision == revision;
    }

    /// Apply a queued edit to the buffer named by the edit's path.
    pub fn applyReview(self: *Workspace, queue: *review.ReviewQueue, index: usize) !review.Outcome {
        const edit = queue.editAt(index);
        const buffer_index = self.findBuffer(edit.path) orelse return .invalid;
        return queue.apply(index, &self.buffers.items[buffer_index].document);
    }
};
