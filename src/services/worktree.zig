const std = @import("std");
const c = @import("native");
const Allocator = std.mem.Allocator;

/// Result of a synchronous git command.
pub const GitResult = struct {
    exit: c_int,
    stdout: []u8,
};

/// Run `git <argv...>` synchronously from `cwd`, capturing stdout.
/// The caller owns `result.stdout`.
pub fn run(a: Allocator, cwd: []const u8, argv: []const []const u8) !GitResult {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tmp = arena.allocator();
    const full = try tmp.alloc(?[*:0]const u8, argv.len + 2);
    full[0] = "git";
    for (argv, 0..) |arg, i| full[i + 1] = (try tmp.dupeSentinel(u8, arg, 0)).ptr;
    full[argv.len + 1] = null;
    const cwd_z = try tmp.dupeSentinel(u8, cwd, 0);

    const props = c.SDL_CreateProperties();
    if (props == 0) return error.GitProperties;
    defer c.SDL_DestroyProperties(props);
    if (!c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, @ptrCast(full.ptr)) or
        !c.SDL_SetStringProperty(props, c.SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, cwd_z.ptr) or
        !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, c.SDL_PROCESS_STDIO_APP) or
        !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, c.SDL_PROCESS_STDIO_INHERITED)) return error.GitProperties;

    const process = c.SDL_CreateProcessWithProperties(props) orelse return error.GitSpawn;
    defer c.SDL_DestroyProcess(process);
    const output = c.SDL_GetProcessOutput(process) orelse return error.GitPipe;

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const count = c.SDL_ReadIO(output, &buf, buf.len);
        if (count > 0) {
            try stdout.appendSlice(a, buf[0..count]);
        } else switch (c.SDL_GetIOStatus(output)) {
            c.SDL_IO_STATUS_EOF => break,
            c.SDL_IO_STATUS_NOT_READY, c.SDL_IO_STATUS_READY => c.SDL_Delay(1),
            else => return error.GitRead,
        }
    }
    var exit_code: c_int = 0;
    if (!c.SDL_WaitProcess(process, true, &exit_code)) return error.GitWait;
    return .{ .exit = exit_code, .stdout = try stdout.toOwnedSlice(a) };
}

/// Create a linked worktree on a new branch from the repo's current HEAD.
pub fn createWorktree(a: Allocator, repo: []const u8, branch: []const u8, path: []const u8) !void {
    const result = try run(a, repo, &.{ "worktree", "add", "-b", branch, path });
    defer a.free(result.stdout);
    if (result.exit != 0) return error.WorktreeFailed;
}

/// True when the working tree has unmerged (conflicted) files.
pub fn hasConflicts(a: Allocator, path: []const u8) !bool {
    const result = try run(a, path, &.{ "diff", "--name-only", "--diff-filter=U" });
    defer a.free(result.stdout);
    if (result.exit != 0) return error.GitFailed;
    return result.stdout.len > 0;
}
