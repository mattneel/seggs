const std = @import("std");
const builtin = @import("builtin");
const c = @import("std").c;

/// A PTY with a child process (the shell) attached to its slave end, or, on a
/// platform that has no `forkpty`, a type that refuses instead. The choice is
/// comptime so the POSIX declarations are never analyzed where they cannot
/// link, which is what a bare `extern fn` in this file used to cost.
pub const Pty = if (builtin.os.tag == .windows) Unsupported else Posix;

const Unsupported = struct {
    pub fn spawn(_: std.mem.Allocator, _: []const []const u8) !Unsupported {
        return error.PtyUnsupported;
    }

    pub fn readOutput(_: *Unsupported, _: []u8) !usize {
        return error.PtyUnsupported;
    }

    pub fn writeInput(_: *Unsupported, _: []const u8) !void {
        return error.PtyUnsupported;
    }

    /// The editor polls the PTY; there is nothing to poll where there is none.
    pub fn setNonBlocking(_: *Unsupported) !void {}

    pub fn deinit(_: *Unsupported) void {}
};

/// The parent reads and writes the master end; the child runs on the slave.
const Posix = struct {
    allocator: std.mem.Allocator,
    master: c_int,
    pid: c_int,

    extern fn forkpty(amaster: *c_int, name: ?*anyopaque, termp: ?*anyopaque, winp: ?*anyopaque) c_int;
    extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern fn close(fd: c_int) c_int;
    extern fn execvp(file: [*:0]const u8, argv: ?*anyopaque) c_int;

    pub fn spawn(a: std.mem.Allocator, argv: []const []const u8) !Posix {
        if (argv.len == 0) return error.EmptyCommand;
        var master: c_int = 0;
        const pid = forkpty(&master, null, null, null);
        if (pid < 0) return error.Forkpty;
        if (pid == 0) {
            // Child: run the command on the slave terminal.
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const tmp = arena.allocator();
            const args = try tmp.alloc(?[*:0]const u8, argv.len + 1);
            for (argv, 0..) |arg, i| args[i] = (try tmp.dupeSentinel(u8, arg, 0)).ptr;
            args[argv.len] = null;
            _ = execvp(args[0].?, @ptrCast(args.ptr));
            std.process.exit(127);
        }
        return .{ .allocator = a, .master = master, .pid = pid };
    }

    /// Reads whatever the program has said, and nothing when it has said
    /// nothing: a polled PTY reports the empty read rather than waiting.
    pub fn readOutput(self: *Posix, buf: []u8) !usize {
        return std.posix.read(self.master, buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => error.PtyRead,
        };
    }

    pub fn writeInput(self: *Posix, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = write(self.master, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0) return error.PtyWrite;
            offset += @intCast(n);
        }
    }

    /// A blocking read would stall the frame loop on a shell that simply has
    /// nothing to say yet, so the editor polls instead.
    pub fn setNonBlocking(self: *Posix) !void {
        const flags = c.fcntl(self.master, std.posix.F.GETFL);
        if (flags < 0) return error.PtyFlags;
        const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
        if (c.fcntl(self.master, std.posix.F.SETFL, flags | @as(c_int, @intCast(nonblock))) < 0) return error.PtyFlags;
    }

    pub fn deinit(self: *Posix) void {
        _ = close(self.master);
    }
};
