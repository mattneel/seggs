const std = @import("std");

extern fn forkpty(amaster: *c_int, name: ?*anyopaque, termp: ?*anyopaque, winp: ?*anyopaque) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn execvp(file: [*:0]const u8, argv: ?*anyopaque) c_int;

/// A PTY with a child process (the shell) attached to its slave end.
/// The parent reads and writes the master end.
pub const Pty = struct {
    allocator: std.mem.Allocator,
    master: c_int,
    pid: c_int,

    pub fn spawn(a: std.mem.Allocator, argv: []const []const u8) !Pty {
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

    pub fn readOutput(self: *Pty, buf: []u8) !usize {
        const n = read(self.master, buf.ptr, buf.len);
        if (n < 0) return error.PtyRead;
        return @intCast(n);
    }

    pub fn writeInput(self: *Pty, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = write(self.master, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0) return error.PtyWrite;
            offset += @intCast(n);
        }
    }

    pub fn deinit(self: *Pty) void {
        _ = close(self.master);
    }
};
