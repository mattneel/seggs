const std = @import("std");
const c = @import("native");
const Allocator = std.mem.Allocator;

fn encodeFrame(a: Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

fn parseContentLength(header: []const u8) ?usize {
    const marker = "Content-Length: ";
    if (header.len < marker.len or !std.mem.eql(u8, header[0..marker.len], marker)) return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, header[marker.len..], "\r\n "), 10) catch null;
}

/// A stack frame reported by the adapter.
pub const Frame = struct {
    name: []u8,
    line: u32,

    pub fn deinit(self: Frame, a: Allocator) void {
        a.free(self.name);
    }
};

/// A named variable and its rendered value.
pub const Variable = struct {
    name: []u8,
    value: []u8,

    pub fn deinit(self: Variable, a: Allocator) void {
        a.free(self.name);
        a.free(self.value);
    }
};

/// Release a list returned by `Client.stackTrace`.
pub fn freeFrames(a: Allocator, list: []Frame) void {
    for (list) |frame| frame.deinit(a);
    a.free(list);
}

/// Release a list returned by `Client.variables`.
pub fn freeVariables(a: Allocator, list: []Variable) void {
    for (list) |variable| variable.deinit(a);
    a.free(list);
}

/// A minimal synchronous DAP client: spawn an adapter, launch a program with a
/// breakpoint, observe the stopped event, then inspect and resume the session.
/// Uses the DAP message schema (`seq`/`type`/`command`), not JSON-RPC.
pub const Client = struct {
    allocator: Allocator,
    process: *c.SDL_Process,
    input: *c.SDL_IOStream,
    output: *c.SDL_IOStream,
    stopped: bool = false,
    seq: u64 = 1,
    /// Deadline for one blocking read, in milliseconds.
    timeout_ms: u64 = 15_000,

    pub fn start(a: Allocator, argv: []const []const u8, cwd: []const u8) !Client {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const tmp = arena.allocator();
        const args = try tmp.alloc(?[*:0]const u8, argv.len + 1);
        for (argv, 0..) |arg, i| args[i] = (try tmp.dupeSentinel(u8, arg, 0)).ptr;
        args[argv.len] = null;
        const cwd_z = try tmp.dupeSentinel(u8, cwd, 0);
        const props = c.SDL_CreateProperties();
        if (props == 0) return error.DapProperties;
        defer c.SDL_DestroyProperties(props);
        if (!c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, @ptrCast(args.ptr)) or
            !c.SDL_SetStringProperty(props, c.SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, cwd_z.ptr) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, c.SDL_PROCESS_STDIO_APP) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, c.SDL_PROCESS_STDIO_APP) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, c.SDL_PROCESS_STDIO_INHERITED)) return error.DapProperties;
        const process = c.SDL_CreateProcessWithProperties(props) orelse return error.DapSpawn;
        errdefer {
            _ = c.SDL_KillProcess(process, true);
            _ = c.SDL_WaitProcess(process, true, null);
            c.SDL_DestroyProcess(process);
        }
        const input = c.SDL_GetProcessInput(process) orelse return error.DapPipe;
        const output = c.SDL_GetProcessOutput(process) orelse return error.DapPipe;
        return .{ .allocator = a, .process = process, .input = input, .output = output };
    }

    pub fn deinit(self: *Client) void {
        _ = c.SDL_KillProcess(self.process, true);
        _ = c.SDL_WaitProcess(self.process, true, null);
        c.SDL_DestroyProcess(self.process);
    }

    fn sendRaw(self: *Client, body: []const u8) !void {
        const frame = try encodeFrame(self.allocator, body);
        defer self.allocator.free(frame);
        var offset: usize = 0;
        while (offset < frame.len) {
            const written = c.SDL_WriteIO(self.input, frame[offset..].ptr, frame.len - offset);
            if (written == 0 and c.SDL_GetIOStatus(self.input) != c.SDL_IO_STATUS_NOT_READY) return error.DapWrite;
            offset += @intCast(written);
        }
    }

    fn readExact(self: *Client, a: Allocator, n: usize, deadline: u64) !?[]u8 {
        const buf = try a.alloc(u8, n);
        errdefer a.free(buf);
        var offset: usize = 0;
        while (offset < n) {
            const count = c.SDL_ReadIO(self.output, buf[offset..].ptr, n - offset);
            if (count > 0) {
                offset += @intCast(count);
            } else if (c.SDL_GetTicks() > deadline) {
                return null;
            } else {
                c.SDL_Delay(1);
            }
        }
        return buf;
    }

    fn readFrame(self: *Client, a: Allocator, deadline: u64) !?[]u8 {
        var header: std.ArrayList(u8) = .empty;
        errdefer header.deinit(a);
        while (std.mem.indexOf(u8, header.items, "\r\n\r\n") == null) {
            const byte = (try self.readExact(a, 1, deadline)) orelse return null;
            defer a.free(byte);
            try header.append(a, byte[0]);
        }
        const end = std.mem.indexOf(u8, header.items, "\r\n\r\n").?;
        const content_length = parseContentLength(header.items[0..end]) orelse return error.DapHeader;
        header.deinit(a);
        return self.readExact(a, content_length, deadline);
    }

    /// Send a request and return the sequence number it used.
    fn request(self: *Client, command: []const u8, arguments: []const u8) !u64 {
        const id = self.seq;
        const body = try std.fmt.allocPrint(self.allocator, "{{\"seq\":{d},\"type\":\"request\",\"command\":\"{s}\",\"arguments\":{s}}}", .{ id, command, arguments });
        defer self.allocator.free(body);
        self.seq += 1;
        try self.sendRaw(body);
        return id;
    }

    /// Wait for the response to `id`. Returns null on timeout.
    fn awaitResponse(self: *Client, id: u64) !?std.json.Parsed(std.json.Value) {
        const deadline = c.SDL_GetTicks() + self.timeout_ms;
        while (true) {
            const frame = (try self.readFrame(self.allocator, deadline)) orelse return null;
            defer self.allocator.free(frame);
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{}) catch continue;
            const value = parsed.value;
            if (value != .object or !std.mem.eql(u8, strField(value, "type"), "response")) {
                noteEvent(self, value);
                parsed.deinit();
                continue;
            }
            const request_seq = intField(value, "request_seq") orelse -1;
            if (request_seq < 0 or @as(u64, @intCast(request_seq)) != id) {
                parsed.deinit();
                continue;
            }
            if (!boolField(value, "success")) {
                parsed.deinit();
                return error.DapRequestFailed;
            }
            return parsed;
        }
    }

    /// Wait for an event named `name`, skipping responses and other events.
    fn awaitEvent(self: *Client, name: []const u8) !?std.json.Parsed(std.json.Value) {
        const deadline = c.SDL_GetTicks() + self.timeout_ms;
        while (true) {
            const frame = (try self.readFrame(self.allocator, deadline)) orelse return null;
            defer self.allocator.free(frame);
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{}) catch continue;
            const value = parsed.value;
            if (value == .object and std.mem.eql(u8, strField(value, "type"), "event") and std.mem.eql(u8, strField(value, "event"), name)) return parsed;
            noteEvent(self, value);
            parsed.deinit();
        }
    }

    fn noteEvent(self: *Client, value: std.json.Value) void {
        if (value != .object or !std.mem.eql(u8, strField(value, "type"), "event")) return;
        const event = strField(value, "event");
        if (std.mem.eql(u8, event, "stopped")) self.stopped = true;
        if (std.mem.eql(u8, event, "continued")) self.stopped = false;
    }

    /// Launch a program with a breakpoint and block until the stopped event.
    pub fn launch(self: *Client, program: []const u8, breakpoint_line: u32) !void {
        _ = try self.request("initialize", "{\"adapterID\":\"mock\"}");
        const launch_args = try std.fmt.allocPrint(self.allocator, "{{\"program\":\"{s}\"}}", .{program});
        defer self.allocator.free(launch_args);
        _ = try self.request("launch", launch_args);
        const bp_args = try std.fmt.allocPrint(self.allocator, "{{\"source\":{{\"path\":\"{s}\"}},\"breakpoints\":[{{\"line\":{d}}}]}}", .{ program, breakpoint_line });
        defer self.allocator.free(bp_args);
        _ = try self.request("setBreakpoints", bp_args);
        _ = try self.request("configurationDone", "{}");
        try self.awaitStop();
    }

    fn awaitStop(self: *Client) !void {
        const event = (try self.awaitEvent("stopped")) orelse return error.DapTimeout;
        event.deinit();
        self.stopped = true;
    }

    /// Resume the stopped thread and wait for the next stopped event.
    /// `command` is `continue`, `next`, `stepIn`, or `stepOut`.
    pub fn resumeThread(self: *Client, command: []const u8) !void {
        const id = try self.request(command, "{\"threadId\":1}");
        if (try self.awaitResponse(id)) |response| response.deinit();
        self.stopped = false;
        try self.awaitStop();
    }

    /// Stack frames for the stopped thread. Caller owns the list.
    pub fn stackTrace(self: *Client) ![]Frame {
        var list: std.ArrayList(Frame) = .empty;
        errdefer {
            for (list.items) |frame| frame.deinit(self.allocator);
            list.deinit(self.allocator);
        }
        const id = try self.request("stackTrace", "{\"threadId\":1}");
        if (try self.awaitResponse(id)) |parsed| {
            defer parsed.deinit();
            if (field(parsed.value, "body")) |body| {
                if (field(body, "stackFrames")) |frames| {
                    if (frames == .array) {
                        for (frames.array.items) |item| {
                            try list.append(self.allocator, .{
                                .name = try self.allocator.dupe(u8, strField(item, "name")),
                                .line = @intCast(intField(item, "line") orelse 0),
                            });
                        }
                    }
                }
            }
        }
        return list.toOwnedSlice(self.allocator);
    }

    /// Variables reference of the first scope, or null when none is reported.
    pub fn firstScope(self: *Client) !?i64 {
        const id = try self.request("scopes", "{\"frameId\":1}");
        const parsed = (try self.awaitResponse(id)) orelse return null;
        defer parsed.deinit();
        const body = field(parsed.value, "body") orelse return null;
        const scopes = field(body, "scopes") orelse return null;
        if (scopes != .array or scopes.array.items.len == 0) return null;
        return intField(scopes.array.items[0], "variablesReference");
    }

    /// Variables for a reference. Caller owns the list.
    pub fn variables(self: *Client, reference: i64) ![]Variable {
        var list: std.ArrayList(Variable) = .empty;
        errdefer {
            for (list.items) |variable| variable.deinit(self.allocator);
            list.deinit(self.allocator);
        }
        var buffer: [64]u8 = undefined;
        const arguments = try std.fmt.bufPrint(&buffer, "{{\"variablesReference\":{d}}}", .{reference});
        const id = try self.request("variables", arguments);
        if (try self.awaitResponse(id)) |parsed| {
            defer parsed.deinit();
            if (field(parsed.value, "body")) |body| {
                if (field(body, "variables")) |entries| {
                    if (entries == .array) {
                        for (entries.array.items) |item| {
                            try list.append(self.allocator, .{
                                .name = try self.allocator.dupe(u8, strField(item, "name")),
                                .value = try self.allocator.dupe(u8, strField(item, "value")),
                            });
                        }
                    }
                }
            }
        }
        return list.toOwnedSlice(self.allocator);
    }
};

fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}

fn strField(value: std.json.Value, key: []const u8) []const u8 {
    const found = field(value, key) orelse return "";
    return if (found == .string) found.string else "";
}

fn intField(value: std.json.Value, key: []const u8) ?i64 {
    const found = field(value, key) orelse return null;
    return if (found == .integer) found.integer else null;
}

fn boolField(value: std.json.Value, key: []const u8) bool {
    const found = field(value, key) orelse return false;
    return if (found == .bool) found.bool else false;
}
