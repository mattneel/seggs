const std = @import("std");
const worktree = @import("worktree.zig");
const Allocator = std.mem.Allocator;

/// Short status (`git status --porcelain`), one line per changed file.
/// The caller owns the returned buffer.
pub fn status(a: Allocator, path: []const u8) ![]u8 {
    const result = try worktree.run(a, path, &.{ "status", "--porcelain" });
    if (result.exit != 0) {
        a.free(result.stdout);
        return error.GitFailed;
    }
    return result.stdout;
}

/// Unified diff of uncommitted changes (`git diff`).
/// The caller owns the returned buffer.
pub fn diff(a: Allocator, path: []const u8) ![]u8 {
    const result = try worktree.run(a, path, &.{"diff"});
    if (result.exit != 0) {
        a.free(result.stdout);
        return error.GitFailed;
    }
    return result.stdout;
}
