const std = @import("std");
const c = @import("native");
const Allocator = std.mem.Allocator;

pub fn read(a: Allocator, path: []const u8, limit: usize) ![]u8 {
    const z = try a.dupeZ(u8, path);
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

/// The temporary file resides beside the destination. See docs/LIMITATIONS.md.
pub fn replace(a: Allocator, path: []const u8, bytes: []const u8) !void {
    const temp_name = try std.fmt.allocPrint(a, "{s}.seggs-tmp-{d}", .{ path, c.SDL_GetPerformanceCounter() });
    defer a.free(temp_name);
    const temp = try a.dupeZ(u8, temp_name);
    defer a.free(temp);
    const target = try a.dupeZ(u8, path);
    defer a.free(target);
    // Exclusive creation prevents an existing temporary file from being truncated.
    const file = c.fopen(temp.ptr, "wbx") orelse return error.SaveTemporary;
    var closed = false;
    defer if (!closed) _ = c.fclose(file);
    defer _ = c.SDL_RemovePath(temp.ptr);
    if (c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.FileWrite;
    if (c.fflush(file) != 0) return error.FileFlush;
    const close_result = c.fclose(file);
    closed = true;
    if (close_result != 0) return error.FileClose;
    if (!c.SDL_RenamePath(temp.ptr, target.ptr)) return error.FileRename;
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
        const path = try a.dupeZ(u8, root);
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
        for ([_][]const u8{ ".git", ".zig-cache", "zig-out", "node_modules", ".deps", ".venv", "__pycache__" }) |skip| {
            if (std.mem.eql(u8, name, skip)) return;
        }
        if (self.entries.items.len >= 1024) {
            self.truncated = true;
            return;
        }
        const joined = try std.fs.path.join(self.allocator, &.{ directory, name });
        defer self.allocator.free(joined);
        const path = try self.allocator.dupeZ(u8, joined);
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
