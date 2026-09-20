const std = @import("std");
const c = @import("native");
const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    message: []u8,
    line: u32,
};

/// Frame an LSP message with a Content-Length header. Caller owns the result.
pub fn encodeFrame(a: Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

fn parseContentLength(header: []const u8) ?usize {
    const marker = "Content-Length: ";
    if (header.len < marker.len or !std.mem.eql(u8, header[0..marker.len], marker)) return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, header[marker.len..], "\r\n "), 10) catch null;
}

/// A minimal synchronous LSP client: spawn a server, initialize, open a
/// document, and collect publishDiagnostics. The mock server keeps the
/// exchange deterministic for tests; a real server (clangd/zls) uses the
/// same stdio framing.
pub const Client = struct {
    allocator: Allocator,
    process: *c.SDL_Process,
    input: *c.SDL_IOStream,
    output: *c.SDL_IOStream,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    /// Deadline for one blocking read, in milliseconds. The app lowers this so
    /// a slow server cannot stall the UI thread indefinitely.
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
        if (props == 0) return error.LspProperties;
        defer c.SDL_DestroyProperties(props);
        if (!c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, @ptrCast(args.ptr)) or
            !c.SDL_SetStringProperty(props, c.SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, cwd_z.ptr) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, c.SDL_PROCESS_STDIO_APP) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, c.SDL_PROCESS_STDIO_APP) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, c.SDL_PROCESS_STDIO_INHERITED)) return error.LspProperties;
        const process = c.SDL_CreateProcessWithProperties(props) orelse return error.LspSpawn;
        errdefer {
            _ = c.SDL_KillProcess(process, true);
            _ = c.SDL_WaitProcess(process, true, null);
            c.SDL_DestroyProcess(process);
        }
        const input = c.SDL_GetProcessInput(process) orelse return error.LspPipe;
        const output = c.SDL_GetProcessOutput(process) orelse return error.LspPipe;
        return .{ .allocator = a, .process = process, .input = input, .output = output };
    }

    pub fn deinit(self: *Client) void {
        for (self.diagnostics.items) |d| self.allocator.free(d.message);
        self.diagnostics.deinit(self.allocator);
        _ = c.SDL_KillProcess(self.process, true);
        _ = c.SDL_WaitProcess(self.process, true, null);
        c.SDL_DestroyProcess(self.process);
    }

    fn send(self: *Client, body: []const u8) !void {
        const frame = try encodeFrame(self.allocator, body);
        defer self.allocator.free(frame);
        var offset: usize = 0;
        while (offset < frame.len) {
            const written = c.SDL_WriteIO(self.input, frame[offset..].ptr, frame.len - offset);
            if (written == 0 and c.SDL_GetIOStatus(self.input) != c.SDL_IO_STATUS_NOT_READY) return error.LspWrite;
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
        const content_length = parseContentLength(header.items[0..end]) orelse return error.LspHeader;
        header.deinit(a);
        return self.readExact(a, content_length, deadline);
    }

    fn sendRequest(self: *Client, id: u64, method: []const u8, params: []const u8) !void {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
        defer self.allocator.free(body);
        try self.send(body);
    }

    fn sendNotification(self: *Client, method: []const u8, params: []const u8) !void {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params });
        defer self.allocator.free(body);
        try self.send(body);
    }

    /// Initialize the session and open a document. Blocks until the server
    /// acknowledges and sends the first publishDiagnostics.
    pub fn open(self: *Client, path: []const u8, content: []const u8) !void {
        const deadline = c.SDL_GetTicks() + self.timeout_ms;
        try self.sendRequest(1, "initialize", "{\"capabilities\":{}}");
        try self.sendNotification("initialized", "{}");
        const a = self.allocator;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        try text.appendSlice(a, "{\"textDocument\":{\"uri\":\"file://");
        try appendEscaped(&text, a, path);
        try text.appendSlice(a, "\",\"languageId\":\"plaintext\",\"version\":1,\"text\":\"");
        try appendEscaped(&text, a, content);
        try text.appendSlice(a, "\"}}");
        try self.sendNotification("textDocument/didOpen", text.items);
        // Drain responses until publishDiagnostics arrives.
        while (true) {
            const frame = (try self.readFrame(self.allocator, deadline)) orelse return error.LspTimeout;
            defer self.allocator.free(frame);
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{}) catch continue;
            defer parsed.deinit();
            if (std.mem.eql(u8, str(parsed.value, "method"), "textDocument/publishDiagnostics")) {
                const params = field(parsed.value, "params") orelse continue;
                const list = field(params, "diagnostics") orelse continue;
                if (list != .array) continue;
                for (list.array.items) |item| {
                    const message = str(item, "message");
                    const range = field(item, "range") orelse continue;
                    const start_pos = field(range, "start") orelse continue;
                    const line = integer(field(start_pos, "line") orelse continue) orelse 0;
                    try self.diagnostics.append(self.allocator, .{
                        .message = try self.allocator.dupe(u8, message),
                        .line = @intCast(line),
                    });
                }
                return;
            }
        }
    }

    /// Build `textDocument` + `position` params for a request.
    fn positionParams(self: *Client, path: []const u8, line: u32, character: u32) ![]u8 {
        const a = self.allocator;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.appendSlice(a, "{\"textDocument\":{\"uri\":\"file://");
        try appendEscaped(&out, a, path);
        try out.appendSlice(a, "\"},\"position\":{\"line\":");
        try appendNumber(&out, a, line);
        try out.appendSlice(a, ",\"character\":");
        try appendNumber(&out, a, character);
        try out.appendSlice(a, "}}");
        return out.toOwnedSlice(a);
    }

    /// Send a request and return the parsed response matching `id`.
    /// Notifications and unrelated responses are skipped.
    fn request(self: *Client, id: u64, method: []const u8, params: []const u8) !std.json.Parsed(std.json.Value) {
        const deadline = c.SDL_GetTicks() + self.timeout_ms;
        try self.sendRequest(id, method, params);
        while (true) {
            const frame = (try self.readFrame(self.allocator, deadline)) orelse return error.LspTimeout;
            defer self.allocator.free(frame);
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{}) catch continue;
            const response_id = field(parsed.value, "id") orelse {
                parsed.deinit();
                continue;
            };
            if (response_id != .integer or @as(u64, @intCast(response_id.integer)) != id) {
                parsed.deinit();
                continue;
            }
            if (field(parsed.value, "result") == null) {
                parsed.deinit();
                return error.LspError;
            }
            return parsed;
        }
    }

    /// `textDocument/definition` at a position. Returns the first location the
    /// server reports, or null. Caller owns the result.
    pub fn definition(self: *Client, path: []const u8, line: u32, character: u32) !?Location {
        const params = try self.positionParams(path, line, character);
        defer self.allocator.free(params);
        const parsed = try self.request(2, "textDocument/definition", params);
        defer parsed.deinit();
        const result = field(parsed.value, "result") orelse return null;
        if (result == .array) {
            if (result.array.items.len == 0) return null;
            return parseLocation(self.allocator, result.array.items[0]);
        }
        return parseLocation(self.allocator, result);
    }

    /// `textDocument/references` at a position. Caller owns the returned list
    /// and releases it with `freeLocations`.
    pub fn references(self: *Client, path: []const u8, line: u32, character: u32) ![]Location {
        const a = self.allocator;
        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(a);
        try params.appendSlice(a, "{\"textDocument\":{\"uri\":\"file://");
        try appendEscaped(&params, a, path);
        try params.appendSlice(a, "\"},\"position\":{\"line\":");
        try appendNumber(&params, a, line);
        try params.appendSlice(a, ",\"character\":");
        try appendNumber(&params, a, character);
        try params.appendSlice(a, "},\"context\":{\"includeDeclaration\":true}}");
        const parsed = try self.request(3, "textDocument/references", params.items);
        defer parsed.deinit();
        var list: std.ArrayList(Location) = .empty;
        errdefer {
            for (list.items) |location| location.deinit(self.allocator);
            list.deinit(self.allocator);
        }
        if (field(parsed.value, "result")) |result| {
            if (result == .array) {
                for (result.array.items) |item| {
                    if (try parseLocation(self.allocator, item)) |location| try list.append(self.allocator, location);
                }
            }
        }
        return list.toOwnedSlice(self.allocator);
    }

    /// `textDocument/hover` at a position. Caller owns the returned text.
    pub fn hover(self: *Client, path: []const u8, line: u32, character: u32) !?[]u8 {
        const params = try self.positionParams(path, line, character);
        defer self.allocator.free(params);
        const parsed = try self.request(4, "textDocument/hover", params);
        defer parsed.deinit();
        const result = field(parsed.value, "result") orelse return null;
        const contents = field(result, "contents") orelse return null;
        const text = switch (contents) {
            .string => |value| value,
            .object => str(contents, "value"),
            .array => if (contents.array.items.len > 0) str(contents.array.items[0], "value") else "",
            else => "",
        };
        if (text.len == 0) return null;
        return try self.allocator.dupe(u8, text);
    }
};

/// An LSP location: a file path plus a zero-based line and character.
pub const Location = struct {
    path: []u8,
    line: u32,
    character: u32,

    pub fn deinit(self: Location, a: Allocator) void {
        a.free(self.path);
    }
};

/// Release a list returned by `Client.references`.
pub fn freeLocations(a: Allocator, list: []Location) void {
    for (list) |location| location.deinit(a);
    a.free(list);
}

/// Escape `value` as the body of a JSON string, without surrounding quotes.
/// Document text reaches the server through this path, so newlines, quotes,
/// and backslashes must be escaped or the frame is not valid JSON.
fn appendEscaped(out: *std.ArrayList(u8), a: Allocator, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => if (byte < 0x20) {
                var buffer: [8]u8 = undefined;
                try out.appendSlice(a, try std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{byte}));
            } else try out.append(a, byte),
        }
    }
}

fn appendNumber(out: *std.ArrayList(u8), a: Allocator, value: u32) !void {
    var buffer: [16]u8 = undefined;
    try out.appendSlice(a, try std.fmt.bufPrint(&buffer, "{d}", .{value}));
}

fn parseLocation(a: Allocator, value: std.json.Value) !?Location {
    const uri = str(value, "uri");
    if (uri.len == 0) return null;
    const range = field(value, "range") orelse return null;
    const start = field(range, "start") orelse return null;
    const line = integer(field(start, "line") orelse return null) orelse return null;
    const character = integer(field(start, "character") orelse return null) orelse return null;
    const prefix = "file://";
    const path = if (std.mem.startsWith(u8, uri, prefix)) uri[prefix.len..] else uri;
    return .{ .path = try a.dupe(u8, path), .line = @intCast(line), .character = @intCast(character) };
}

fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}

fn str(value: std.json.Value, key: []const u8) []const u8 {
    const v = field(value, key) orelse return "";
    return if (v == .string) v.string else "";
}

fn integer(value: std.json.Value) ?i64 {
    return if (value == .integer) value.integer else null;
}
