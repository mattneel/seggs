const std = @import("std");
const builtin = @import("builtin");
const c = @import("native");
const Allocator = std.mem.Allocator;

/// A writable path under the system's temporary directory, for callers that
/// need a scratch file. The environment decides the directory, so the same code
/// runs on a POSIX host and on Windows, where `/tmp` is not a location.
pub fn tempPath(a: Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    const base: []const u8 = if (std.c.getenv(if (builtin.os.tag == .windows) "TEMP" else "TMPDIR")) |value|
        std.mem.span(value)
    else
        if (builtin.os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
    return std.fmt.allocPrint(a, "{s}{c}seggs-{s}-{d}{s}", .{
        base,
        std.fs.path.sep,
        prefix,
        c.SDL_GetPerformanceCounter(),
        suffix,
    });
}

pub fn read(a: Allocator, path: []const u8, limit: usize) ![]u8 {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const stream = c.SDL_IOFromFile(z.ptr, "rb") orelse return error.FileOpen;
    defer _ = c.SDL_CloseIO(stream);
    const size = c.SDL_GetIOSize(stream);
    if (size < 0 or @as(u64, @intCast(size)) > @as(u64, limit)) return error.FileTooLarge;
    const bytes = try a.alloc(u8, @intCast(size));
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.SDL_ReadIO(stream, bytes[offset..].ptr, bytes.len - offset);
        if (count == 0) return error.FileRead;
        offset += count;
    }
    return bytes;
}

/// Resolve `path` so a save through a symlink replaces the file the link names
/// instead of replacing the link itself. A path that does not resolve yet, and
/// every path on Windows, keeps its literal form so a new file is still created
/// where the caller asked.
fn realTarget(a: Allocator, path: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) return a.dupe(u8, path);
    const path_z = try a.dupeSentinel(u8, path, 0);
    defer a.free(path_z);
    var buffer: [4096]u8 = undefined;
    const resolved = c.realpath(path_z.ptr, &buffer) orelse return a.dupe(u8, path);
    return a.dupe(u8, std.mem.span(resolved));
}

/// The temporary file resides beside the resolved destination.
/// See docs/LIMITATIONS.md.
pub fn replace(a: Allocator, path: []const u8, bytes: []const u8) !void {
    const destination = try realTarget(a, path);
    defer a.free(destination);
    const temp_name = try std.fmt.allocPrint(a, "{s}.seggs-tmp-{d}", .{ destination, c.SDL_GetPerformanceCounter() });
    defer a.free(temp_name);
    const temp = try a.dupeSentinel(u8, temp_name, 0);
    defer a.free(temp);
    const target = try a.dupeSentinel(u8, destination, 0);
    defer a.free(target);
    // Exclusive creation prevents an existing temporary file from being truncated.
    const file = c.fopen(temp.ptr, "wbx") orelse return error.SaveTemporary;
    var closed = false;
    defer {
        if (!closed) _ = c.fclose(file);
    }
    defer _ = c.SDL_RemovePath(temp.ptr);
    if (c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.FileWrite;
    if (c.fflush(file) != 0) return error.FileFlush;
    const close_result = c.fclose(file);
    closed = true;
    if (close_result != 0) return error.FileClose;
    if (!c.SDL_RenamePath(temp.ptr, target.ptr)) return error.FileRename;
}

/// Append the absolute paths of files directly inside `dir` whose names end
/// with `suffix`, sorted for a deterministic load order. A missing or
/// unreadable directory yields no entries rather than an error.
pub fn listMatching(a: Allocator, dir: []const u8, suffix: []const u8, out: *std.ArrayList([]u8)) void {
    const path = a.dupeSentinel(u8, dir, 0) catch return;
    defer a.free(path);
    const Collector = struct {
        allocator: Allocator,
        suffix: []const u8,
        out: *std.ArrayList([]u8),

        fn callback(userdata: ?*anyopaque, directory: [*c]const u8, name: [*c]const u8) callconv(.c) c.SDL_EnumerationResult {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const entry = std.mem.span(name);
            if (std.mem.endsWith(u8, entry, self.suffix)) {
                const joined = std.fs.path.join(self.allocator, &.{ std.mem.span(directory), entry }) catch return c.SDL_ENUM_CONTINUE;
                self.out.append(self.allocator, joined) catch self.allocator.free(joined);
            }
            return c.SDL_ENUM_CONTINUE;
        }
    };
    var collector: Collector = .{ .allocator = a, .suffix = suffix, .out = out };
    _ = c.SDL_EnumerateDirectory(path.ptr, Collector.callback, &collector);
    std.mem.sort([]u8, out.items, {}, struct {
        fn less(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
}

/// On-disk identity used for external-change detection.
pub const FileStamp = struct {
    size: u64,
    modify_time: i64,

    pub fn eql(a: FileStamp, b: FileStamp) bool {
        return a.size == b.size and a.modify_time == b.modify_time;
    }
};

pub fn stamp(a: Allocator, path: []const u8) !FileStamp {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    var info = std.mem.zeroes(c.SDL_PathInfo);
    if (!c.SDL_GetPathInfo(z.ptr, &info)) return error.FileStat;
    return .{ .size = info.size, .modify_time = info.modify_time };
}

/// Stamp of the files matching a suffix inside a directory: the newest
/// modification time and the total size. A directory's own timestamp does not
/// change when a file inside it is rewritten, so watching a directory of bundles
/// has to watch the files.
pub fn dirStamp(a: Allocator, dir: []const u8, suffix: []const u8) !FileStamp {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| a.free(path);
        paths.deinit(a);
    }
    listMatching(a, dir, suffix, &paths);
    var combined: FileStamp = .{ .size = 0, .modify_time = 0 };
    for (paths.items) |path| {
        const one = stamp(a, path) catch continue;
        combined.size +%= one.size;
        combined.modify_time = @max(combined.modify_time, one.modify_time);
    }
    return combined;
}

pub const Explorer = struct {
    allocator: Allocator,
    root: []const u8,
    entries: std.ArrayList([]u8) = .empty,
    truncated: bool = false,
    failure: ?anyerror = null,
    depth: usize = 0,

    pub fn init(a: Allocator, root: []const u8) !Explorer {
        var self: Explorer = .{ .allocator = a, .root = root };
        errdefer self.deinit();
        const path = try a.dupeSentinel(u8, root, 0);
        defer a.free(path);
        if (!c.SDL_EnumerateDirectory(path.ptr, callback, &self)) return error.DirectoryRead;
        if (self.failure) |err| return err;
        std.mem.sort([]u8, self.entries.items, {}, struct {
            fn less(_: void, left: []u8, right: []u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.less);
        return self;
    }

    pub fn deinit(self: *Explorer) void {
        for (self.entries.items) |path| self.allocator.free(path);
        self.entries.deinit(self.allocator);
    }

    fn callback(userdata: ?*anyopaque, directory: [*c]const u8, name: [*c]const u8) callconv(.c) c.SDL_EnumerationResult {
        const self: *Explorer = @ptrCast(@alignCast(userdata.?));
        self.visit(std.mem.span(directory), std.mem.span(name)) catch |err| {
            self.failure = err;
            return c.SDL_ENUM_FAILURE;
        };
        return if (self.truncated) c.SDL_ENUM_SUCCESS else c.SDL_ENUM_CONTINUE;
    }

    fn visit(self: *Explorer, directory: []const u8, name: []const u8) !void {
        // Directories this project generates, which are not source and would
        // otherwise make the file list depend on what has been built. `.seggs`
        // holds the extension report the editor writes for authors and agents.
        for ([_][]const u8{ ".git", ".zig-cache", "zig-out", "node_modules", ".deps", ".venv", "__pycache__", ".seggs", "zig-pkg", "book" }) |skip| {
            if (std.mem.eql(u8, name, skip)) return;
        }
        if (self.entries.items.len >= 1024) {
            self.truncated = true;
            return;
        }
        const joined = try std.fs.path.join(self.allocator, &.{ directory, name });
        defer self.allocator.free(joined);
        const path = try self.allocator.dupeSentinel(u8, joined, 0);
        defer self.allocator.free(path);
        var info = std.mem.zeroes(c.SDL_PathInfo);
        if (!c.SDL_GetPathInfo(path.ptr, &info)) return;
        if (info.type == c.SDL_PATHTYPE_DIRECTORY) {
            if (self.depth >= 3) return;
            self.depth += 1;
            defer self.depth -= 1;
            if (!c.SDL_EnumerateDirectory(path.ptr, callback, self)) return error.DirectoryRead;
        } else if (info.type == c.SDL_PATHTYPE_FILE) {
            const owned = try self.allocator.dupe(u8, joined);
            errdefer self.allocator.free(owned);
            try self.entries.append(self.allocator, owned);
        }
    }
};
