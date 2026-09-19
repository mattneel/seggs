const std = @import("std");
const Document = @import("document.zig").Document;
const files = @import("../platform/files.zig");

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    document: Document,
    path: ?[]u8 = null,
    baseline: ?[]u8 = null,
    saved_revision: u64 = 0,
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

    pub fn init(a: std.mem.Allocator, root: []const u8) !Workspace {
        var document = try Document.init(a, welcome);
        errdefer document.deinit();
        return .{ .allocator = a, .root = root, .document = document, .explorer = try files.Explorer.init(a, root) };
    }

    pub fn deinit(self: *Workspace) void {
        self.document.deinit();
        self.explorer.deinit();
        if (self.path) |path| self.allocator.free(path);
        if (self.baseline) |bytes| self.allocator.free(bytes);
    }

    pub fn dirty(self: *const Workspace) bool {
        return self.document.revision != self.saved_revision;
    }

    pub fn open(self: *Workspace, path: []const u8) !void {
        if (self.dirty()) return error.UnsavedChanges;
        const bytes = try files.read(self.allocator, path, Document.max_bytes);
        errdefer self.allocator.free(bytes);
        var document = try Document.init(self.allocator, bytes);
        errdefer document.deinit();
        const owned_path = try self.allocator.dupe(u8, path);
        self.document.deinit();
        if (self.path) |old| self.allocator.free(old);
        if (self.baseline) |old| self.allocator.free(old);
        self.path = owned_path;
        self.document = document;
        self.baseline = bytes;
        self.saved_revision = 0;
    }

    pub fn save(self: *Workspace) !void {
        const path = self.path orelse return error.OpenAFileBeforeSave;
        const disk = try files.read(self.allocator, path, Document.max_bytes);
        defer self.allocator.free(disk);
        if (!std.mem.eql(u8, disk, self.baseline.?)) return error.ExternalChangeConflict;
        const bytes = try self.document.snapshot(self.allocator);
        errdefer self.allocator.free(bytes);
        try files.replace(self.allocator, path, bytes);
        self.allocator.free(self.baseline.?);
        self.baseline = bytes;
        self.saved_revision = self.document.revision;
    }
};
