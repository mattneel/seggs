//! Running a command and keeping what it said.
//!
//! A step in a run is evidence about work, so a command's exit status and its
//! output are kept together: a caller downstream has to be able to tell a real
//! result from a hopeful one, and an agent's summary is not a substitute.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("native");
const Allocator = std.mem.Allocator;

pub const Outcome = struct {
    exit: c_int,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Outcome, a: Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
        self.* = undefined;
    }

    pub fn ok(self: Outcome) bool {
        return self.exit == 0;
    }
};

/// Run `argv` synchronously from `cwd`, capturing both streams. The caller owns
/// the result and releases it with `deinit`.
pub fn run(a: Allocator, cwd: []const u8, argv: []const []const u8) !Outcome {
    if (argv.len == 0) return error.EmptyCommand;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tmp = arena.allocator();
    const full = try tmp.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| full[i] = (try tmp.dupeSentinel(u8, arg, 0)).ptr;
    full[argv.len] = null;
    const cwd_z = try tmp.dupeSentinel(u8, cwd, 0);

    const props = c.SDL_CreateProperties();
    if (props == 0) return error.ProcessProperties;
    defer c.SDL_DestroyProperties(props);
    if (!c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, @ptrCast(full.ptr)) or
        !c.SDL_SetStringProperty(props, c.SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, cwd_z.ptr) or
        !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, c.SDL_PROCESS_STDIO_APP) or
        !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, c.SDL_PROCESS_STDIO_APP)) return error.ProcessProperties;

    const process = c.SDL_CreateProcessWithProperties(props) orelse return error.ProcessSpawn;
    defer c.SDL_DestroyProcess(process);
    const out = c.SDL_GetProcessOutput(process) orelse return error.ProcessPipe;
    // Standard error is not a getter on the process: SDL publishes it as a
    // property of the process it created. A command's failure usually *is* its
    // standard error, so it is part of the evidence rather than something to
    // let fall on the floor.
    const properties = c.SDL_GetProcessProperties(process);
    const errors: ?*c.SDL_IOStream = @ptrCast(@alignCast(c.SDL_GetPointerProperty(properties, c.SDL_PROP_PROCESS_STDERR_POINTER, null)));
    if (errors == null) return error.ProcessPipe;

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(a);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(a);

    // Both pipes are drained together: a command that fills the pipe nobody is
    // reading waits forever, and that wait looks exactly like a slow command.
    var buf: [4096]u8 = undefined;
    var out_open = true;
    var err_open = true;
    while (out_open or err_open) {
        var progressed = false;
        if (out_open) {
            const count = c.SDL_ReadIO(out, &buf, buf.len);
            if (count > 0) {
                try stdout.appendSlice(a, buf[0..count]);
                progressed = true;
            } else if (c.SDL_GetIOStatus(out) == c.SDL_IO_STATUS_EOF) {
                out_open = false;
            }
        }
        if (err_open) {
            const count = c.SDL_ReadIO(errors, &buf, buf.len);
            if (count > 0) {
                try stderr.appendSlice(a, buf[0..count]);
                progressed = true;
            } else if (c.SDL_GetIOStatus(errors) == c.SDL_IO_STATUS_EOF) {
                err_open = false;
            }
        }
        if (!progressed and (out_open or err_open)) c.SDL_Delay(1);
    }
    var exit_code: c_int = 0;
    if (!c.SDL_WaitProcess(process, true, &exit_code)) return error.ProcessWait;
    return .{ .exit = exit_code, .stdout = try stdout.toOwnedSlice(a), .stderr = try stderr.toOwnedSlice(a) };
}

// These run a shell to produce output on both streams and a non-zero status.
// Windows has no /bin/sh, and the runner is otherwise covered by the platforms
// where the pipeline itself runs, so the shell cases are skipped there rather
// than rewritten around a different command processor.
const shell_missing = builtin.os.tag == .windows;

test "a command's exit status and output are kept together" {
    if (shell_missing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var outcome = try run(a, ".", &.{ "/bin/sh", "-c", "echo out; echo err >&2; exit 3" });
    defer outcome.deinit(a);
    try std.testing.expectEqual(@as(c_int, 3), outcome.exit);
    try std.testing.expect(!outcome.ok());
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "out") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "err") != null);
}

test "a command that succeeds says so by its status" {
    if (shell_missing) return error.SkipZigTest;
    const a = std.testing.allocator;
    var outcome = try run(a, ".", &.{ "/bin/sh", "-c", "echo done" });
    defer outcome.deinit(a);
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqualStrings("done\n", outcome.stdout);
    try std.testing.expectEqual(@as(usize, 0), outcome.stderr.len);
}
