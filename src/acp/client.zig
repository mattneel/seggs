const std = @import("std");
const c = @import("native");
const rpc = @import("protocol.zig");
const Transport = @import("transport.zig").Transport;
const Agent = @import("../agents/registry.zig").Agent;
const files = @import("../platform/files.zig");
const Allocator = std.mem.Allocator;

/// A client-owned terminal. The agent holds only an id; `terminal/release` or
/// client shutdown reaps the process. Output is bounded so a chatty command
/// cannot grow memory without limit.
const Terminal = struct {
    process: *c.SDL_Process,
    output: *c.SDL_IOStream,
    buffer: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    exit_code: ?c_int = null,
    reaped: bool = false,
    limit: usize = 1 * 1024 * 1024,
};

pub const Client = struct {
    pub const State = enum { offline, initialize, new_session, ready, busy, cancelling, failed };
    const Request = struct { id: u64, kind: enum { initialize, new_session, prompt, set_config }, deadline: u64 };
    pub const Permission = struct { parsed: std.json.Parsed(rpc.Value) };
    const ConfigOption = struct {
        id: []u8,
        value: []u8,
        options: std.ArrayList([]u8) = .empty,
    };
    allocator: Allocator,
    preset: Agent,
    cwd: []const u8,
    transport: ?*Transport = null,
    state: State = .offline,
    session_id: ?[]u8 = null,
    next_id: u64 = 1,
    pending: ?Request = null,
    permission: ?Permission = null,
    transcript: std.ArrayList(u8) = .empty,
    config: std.ArrayList(ConfigOption) = .empty,
    last_error: ?[]u8 = null,
    completed_turns: usize = 0,
    tool_events: usize = 0,
    terminals: std.StringArrayHashMapUnmanaged(*Terminal) = .empty,
    terminal_counter: usize = 0,

    pub fn init(a: Allocator, preset: Agent, cwd: []const u8) Client {
        return .{ .allocator = a, .preset = preset, .cwd = preset.cwd orelse cwd };
    }

    pub fn deinit(self: *Client) void {
        self.stop();
        self.transcript.deinit(self.allocator);
        self.clearConfig();
        self.config.deinit(self.allocator);
        if (self.last_error) |message| self.allocator.free(message);
    }

    pub fn append(self: *Client, bytes: []const u8) !void {
        // Bound transcript memory. Trim only at UTF-8 boundaries.
        const limit = 512 * 1024;
        if (bytes.len >= limit) {
            self.transcript.clearRetainingCapacity();
            var trim_at = bytes.len - limit;
            while (trim_at < bytes.len and bytes[trim_at] & 0xc0 == 0x80) : (trim_at += 1) {}
            try self.transcript.appendSlice(self.allocator, bytes[trim_at..]);
            return;
        }
        if (self.transcript.items.len + bytes.len > limit) {
            var drop = self.transcript.items.len + bytes.len - limit;
            while (drop < self.transcript.items.len and self.transcript.items[drop] & 0xc0 == 0x80) : (drop += 1) {}
            const keep = self.transcript.items.len - drop;
            std.mem.copyForwards(u8, self.transcript.items[0..keep], self.transcript.items[drop..]);
            self.transcript.items.len = keep;
        }
        try self.transcript.appendSlice(self.allocator, bytes);
    }

    fn sendOwned(self: *Client, bytes: []u8) !void {
        defer self.allocator.free(bytes);
        try (self.transport orelse return error.AgentOffline).send(bytes);
    }

    pub fn start(self: *Client) !void {
        if (self.transport != null) return error.AlreadyStarted;
        if (self.last_error) |message| self.allocator.free(message);
        self.last_error = null;
        self.transport = try Transport.start(self.allocator, self.preset.argv, self.cwd);
        errdefer self.stop();
        self.state = .initialize;
        const id = self.next_id;
        self.next_id += 1;
        try self.sendOwned(try rpc.request(self.allocator, id, "initialize", .{
            .protocolVersion = rpc.version,
            .clientInfo = .{ .name = "seggs", .title = "Seggs", .version = "0.1.0" },
            .clientCapabilities = .{
                .fs = .{ .readTextFile = true, .writeTextFile = true },
                .terminal = true,
            },
        }));
        self.pending = .{ .id = id, .kind = .initialize, .deadline = c.SDL_GetTicks() + 30_000 };
        try self.append("\n[ACP] Initialize. Filesystem and isolated terminal capabilities advertised.\n");
    }

    pub fn stop(self: *Client) void {
        if (self.transport) |transport| transport.destroy();
        self.transport = null;
        self.closeTerminals();
        if (self.permission) |*permission| permission.parsed.deinit();
        self.permission = null;
        if (self.session_id) |id| self.allocator.free(id);
        self.session_id = null;
        self.pending = null;
        self.state = .offline;
    }

    fn fail(self: *Client, message: []const u8) void {
        self.stop();
        self.state = .failed;
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = self.allocator.dupe(u8, message) catch null;
        self.append("\n[ERROR] ") catch {};
        self.append(message) catch {};
        self.append("\n") catch {};
    }

    pub fn prompt(self: *Client, text: []const u8) !void {
        if (self.state != .ready) return error.AgentNotReady;
        if (text.len == 0) return;
        if (text.len > 256 * 1024) return error.PromptTooLarge;
        const id = self.next_id;
        self.next_id += 1;
        try self.sendOwned(try rpc.request(self.allocator, id, "session/prompt", .{
            .sessionId = self.session_id.?,
            .prompt = .{.{ .type = "text", .text = text }},
        }));
        self.pending = .{ .id = id, .kind = .prompt, .deadline = 0 };
        self.state = .busy;
        try self.append("\nYOU > ");
        try self.append(text);
        try self.append("\nAGENT > ");
    }

    pub fn cancel(self: *Client) !void {
        if (self.state != .busy and self.state != .cancelling) return;
        if (self.permission != null) try self.answerPermission(false);
        try self.sendOwned(try rpc.notification(self.allocator, "session/cancel", .{ .sessionId = self.session_id.? }));
        self.state = .cancelling;
        if (self.pending) |*pending| pending.deadline = c.SDL_GetTicks() + 10_000;
    }

    /// Process a bounded number of messages per frame for fairness across agents.
    pub fn pump(self: *Client) void {
        self.pumpTerminals();
        const transport = self.transport orelse return;
        var budget: usize = 64;
        while (budget > 0) : (budget -= 1) {
            const line = transport.receive() orelse break;
            defer self.allocator.free(line);
            self.handle(line) catch |err| {
                self.fail(@errorName(err));
                return;
            };
            if (self.transport == null) return;
        }
        if (transport.exitReason() != .none and budget > 0) {
            self.fail(@tagName(transport.exitReason()));
            return;
        }
        if (self.pending) |pending| {
            if (pending.deadline != 0 and c.SDL_GetTicks() > pending.deadline) self.fail("ACP request timeout. Restart the agent after authentication.");
        }
    }

    /// Drain terminal pipes and reap exited processes. Only the app thread
    /// touches this state, so no lock crosses the transport boundary.
    fn pumpTerminals(self: *Client) void {
        for (self.terminals.values()) |terminal| {
            if (terminal.reaped) continue;
            var chunk: [4096]u8 = undefined;
            while (true) {
                const count = c.SDL_ReadIO(terminal.output, &chunk, chunk.len);
                if (count <= 0) break;
                const used: usize = @intCast(count);
                const room = terminal.limit -| terminal.buffer.items.len;
                if (room < used) terminal.truncated = true;
                if (room > 0) terminal.buffer.appendSlice(self.allocator, chunk[0..@min(used, room)]) catch break;
            }
            var status: c_int = 0;
            if (c.SDL_WaitProcess(terminal.process, false, &status)) {
                terminal.exit_code = status;
                terminal.reaped = true;
            }
        }
    }

    fn spawnTerminal(self: *Client, argv: []const []const u8, cwd: []const u8) !*Terminal {
        if (argv.len == 0) return error.EmptyCommand;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        const args = try temp.alloc(?[*:0]const u8, argv.len + 1);
        for (argv, 0..) |arg, i| args[i] = (try temp.dupeSentinel(u8, arg, 0)).ptr;
        args[argv.len] = null;
        const cwd_z = try temp.dupeSentinel(u8, cwd, 0);
        const props = c.SDL_CreateProperties();
        if (props == 0) return error.SdlProperties;
        defer c.SDL_DestroyProperties(props);
        // Stdin is closed and stderr is inherited, so terminal output can never
        // mix into the ACP stdout stream.
        if (!c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, @ptrCast(args.ptr)) or
            !c.SDL_SetStringProperty(props, c.SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, cwd_z.ptr) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, c.SDL_PROCESS_STDIO_NULL) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, c.SDL_PROCESS_STDIO_APP) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, c.SDL_PROCESS_STDIO_INHERITED)) return error.SdlProperties;
        const process = c.SDL_CreateProcessWithProperties(props) orelse return error.TerminalSpawn;
        errdefer {
            _ = c.SDL_KillProcess(process, true);
            _ = c.SDL_WaitProcess(process, true, null);
            c.SDL_DestroyProcess(process);
        }
        const output = c.SDL_GetProcessOutput(process) orelse return error.TerminalPipe;
        const terminal = try self.allocator.create(Terminal);
        terminal.* = .{ .process = process, .output = output };
        return terminal;
    }

    /// Kill if needed, reap, and free one terminal. Ownership ends here.
    fn reapTerminal(self: *Client, terminal: *Terminal) void {
        if (!terminal.reaped) {
            _ = c.SDL_KillProcess(terminal.process, true);
            var status: c_int = 0;
            _ = c.SDL_WaitProcess(terminal.process, true, &status);
        }
        c.SDL_DestroyProcess(terminal.process);
        terminal.buffer.deinit(self.allocator);
        self.allocator.destroy(terminal);
    }

    fn closeTerminal(self: *Client, id: []const u8) void {
        const entry = self.terminals.fetchSwapRemove(id) orelse return;
        self.allocator.free(entry.key);
        self.reapTerminal(entry.value);
    }

    fn closeTerminals(self: *Client) void {
        for (self.terminals.keys()) |key| self.allocator.free(key);
        for (self.terminals.values()) |terminal| self.reapTerminal(terminal);
        self.terminals.deinit(self.allocator);
        self.terminals = .empty;
    }

    fn handle(self: *Client, line: []const u8) !void {
        const parsed = try std.json.parseFromSlice(rpc.Value, self.allocator, line, .{ .allocate = .alloc_always });
        var retained = false;
        defer if (!retained) parsed.deinit();
        const value = parsed.value;
        switch (try rpc.classify(value)) {
            .response => {
                const id = rpc.integer(rpc.field(value, "id").?) orelse return error.UnexpectedResponseId;
                const pending = self.pending orelse return;
                if (id < 0 or @as(u64, @intCast(id)) != pending.id) return;
                self.pending = null;
                if (rpc.field(value, "error")) |agent_error| {
                    const message = rpc.str(agent_error, "message");
                    if (pending.kind == .prompt) {
                        self.state = .ready;
                        if (self.permission != null) try self.answerPermission(false);
                        try self.append("\n[Agent error] ");
                        try self.append(message);
                        try self.append("\n");
                    } else self.fail(if (message.len != 0) message else "Agent initialization failed. Authenticate through the harness CLI.");
                    return;
                }
                const result = rpc.field(value, "result").?;
                switch (pending.kind) {
                    .initialize => {
                        const version = rpc.integer(rpc.field(result, "protocolVersion") orelse return error.ProtocolVersion) orelse return error.ProtocolVersion;
                        if (version != rpc.version) return error.ProtocolVersion;
                        const next = self.next_id;
                        self.next_id += 1;
                        try self.sendOwned(try rpc.request(self.allocator, next, "session/new", .{ .cwd = self.cwd, .mcpServers = [0]struct {}{} }));
                        self.pending = .{ .id = next, .kind = .new_session, .deadline = c.SDL_GetTicks() + 60_000 };
                        self.state = .new_session;
                    },
                    .new_session => {
                        const session = rpc.str(result, "sessionId");
                        if (session.len == 0 or session.len > 4096) return error.InvalidSession;
                        self.session_id = try self.allocator.dupe(u8, session);
                        self.clearConfig();
                        try self.parseConfigOptions(result);
                        self.state = .ready;
                        try self.append("[ACP] Session ready.\n");
                    },
                    .prompt => {
                        if (self.permission != null) try self.answerPermission(false);
                        self.state = .ready;
                        self.completed_turns += 1;
                        try self.append("\n[Stop: ");
                        try self.append(rpc.str(result, "stopReason"));
                        try self.append("]\n");
                    },
                    .set_config => {
                        self.clearConfig();
                        try self.parseConfigOptions(result);
                        self.state = .ready;
                        try self.append("[Config updated]\n");
                    },
                }
            },
            .notification => {
                if (!std.mem.eql(u8, rpc.str(value, "method"), "session/update")) return;
                const params = rpc.field(value, "params") orelse return error.InvalidParams;
                if (!self.matchesSession(params)) return;
                const update = rpc.field(params, "update") orelse return error.InvalidParams;
                const kind = rpc.str(update, "sessionUpdate");
                if (std.mem.eql(u8, kind, "agent_message_chunk")) {
                    const content = rpc.field(update, "content") orelse return;
                    if (std.mem.eql(u8, rpc.str(content, "type"), "text")) try self.append(rpc.str(content, "text"));
                } else if (std.mem.eql(u8, kind, "tool_call") or std.mem.eql(u8, kind, "tool_call_update")) {
                    self.tool_events += 1;
                    try self.append("\n[Tool] ");
                    try self.append(rpc.str(update, "title"));
                    try self.append(" ");
                    try self.append(rpc.str(update, "status"));
                    // Preserve full structured content for inspection in the transcript.
                    const encoded = try std.json.Stringify.valueAlloc(self.allocator, update, .{});
                    defer self.allocator.free(encoded);
                    try self.append("\n");
                    try self.append(encoded);
                    try self.append("\n");
                } else if (std.mem.eql(u8, kind, "plan")) {
                    const encoded = try std.json.Stringify.valueAlloc(self.allocator, update, .{});
                    defer self.allocator.free(encoded);
                    try self.append("\n[Plan] ");
                    try self.append(encoded);
                    try self.append("\n");
                }
                // Unknown extension notifications are optional and are ignored.
            },
            .request => {
                const id = rpc.field(value, "id").?;
                const method = rpc.str(value, "method");
                const params = rpc.field(value, "params") orelse {
                    try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Missing params"));
                    return;
                };
                if (std.mem.eql(u8, method, "session/request_permission")) {
                    if (!self.matchesSession(params) or self.state != .busy or self.permission != null) {
                        try self.sendOwned(try rpc.result(self.allocator, id, .{ .outcome = .{ .outcome = "cancelled" } }));
                        return;
                    }
                    const options = rpc.field(params, "options") orelse return error.InvalidPermission;
                    if (options != .array or options.array.items.len > 32) return error.InvalidPermission;
                    self.permission = .{ .parsed = parsed };
                    retained = true;
                    try self.append("\n[Permission] ");
                    if (rpc.field(params, "toolCall")) |tool| {
                        const encoded = try std.json.Stringify.valueAlloc(self.allocator, tool, .{});
                        defer self.allocator.free(encoded);
                        try self.append(encoded);
                    }
                    try self.append("\nAlt+Y: allow once. Alt+N: reject. Inspect the tool request before approval.\n");
                } else if (std.mem.eql(u8, method, "fs/read_text_file")) {
                    if (!self.matchesSession(params)) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Invalid session"));
                        return;
                    }
                    const path = rpc.str(params, "path");
                    if (path.len == 0) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Missing path"));
                        return;
                    }
                    const content = files.read(self.allocator, path, 8 * 1024 * 1024) catch |err| {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32603, @errorName(err)));
                        return;
                    };
                    defer self.allocator.free(content);
                    if (!std.unicode.utf8ValidateSlice(content)) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32603, "File is not UTF-8 text"));
                        return;
                    }
                    try self.sendOwned(try rpc.result(self.allocator, id, .{ .content = content }));
                } else if (std.mem.eql(u8, method, "fs/write_text_file")) {
                    if (!self.matchesSession(params)) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Invalid session"));
                        return;
                    }
                    const path = rpc.str(params, "path");
                    if (path.len == 0) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Missing path"));
                        return;
                    }
                    const content_value = rpc.field(params, "content") orelse {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Missing content"));
                        return;
                    };
                    const content = rpc.string(content_value) orelse {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Invalid content"));
                        return;
                    };
                    files.replace(self.allocator, path, content) catch |err| {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32603, @errorName(err)));
                        return;
                    };
                    try self.sendOwned(try rpc.result(self.allocator, id, .{}));
                } else if (std.mem.eql(u8, method, "terminal/create")) {
                    if (!self.matchesSession(params)) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Invalid session"));
                        return;
                    }
                    const command = rpc.str(params, "command");
                    if (command.len == 0) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Missing command"));
                        return;
                    }
                    var argv: std.ArrayList([]const u8) = .empty;
                    defer argv.deinit(self.allocator);
                    try argv.append(self.allocator, command);
                    if (rpc.field(params, "args")) |args_value| {
                        if (args_value == .array) {
                            for (args_value.array.items) |item| {
                                if (rpc.string(item)) |argument| try argv.append(self.allocator, argument);
                            }
                        }
                    }
                    const requested_cwd = rpc.str(params, "cwd");
                    const terminal = self.spawnTerminal(argv.items, if (requested_cwd.len > 0) requested_cwd else self.cwd) catch |err| {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32603, @errorName(err)));
                        return;
                    };
                    self.terminal_counter += 1;
                    var key_buffer: [32]u8 = undefined;
                    const key = try std.fmt.bufPrint(&key_buffer, "term-{d}", .{self.terminal_counter});
                    const owned_key = self.allocator.dupe(u8, key) catch |err| {
                        self.reapTerminal(terminal);
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32603, @errorName(err)));
                        return;
                    };
                    self.terminals.put(self.allocator, owned_key, terminal) catch |err| {
                        self.allocator.free(owned_key);
                        self.reapTerminal(terminal);
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32603, @errorName(err)));
                        return;
                    };
                    try self.sendOwned(try rpc.result(self.allocator, id, .{ .terminalId = key }));
                } else if (std.mem.eql(u8, method, "terminal/output")) {
                    if (!self.matchesSession(params)) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Invalid session"));
                        return;
                    }
                    const terminal = self.terminals.get(rpc.str(params, "terminalId")) orelse {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Unknown terminal"));
                        return;
                    };
                    if (terminal.exit_code) |code| {
                        try self.sendOwned(try rpc.result(self.allocator, id, .{
                            .output = terminal.buffer.items,
                            .truncated = terminal.truncated,
                            .exitStatus = .{ .exitCode = code },
                        }));
                    } else {
                        try self.sendOwned(try rpc.result(self.allocator, id, .{
                            .output = terminal.buffer.items,
                            .truncated = terminal.truncated,
                        }));
                    }
                } else if (std.mem.eql(u8, method, "terminal/wait_for_exit")) {
                    if (!self.matchesSession(params)) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Invalid session"));
                        return;
                    }
                    const terminal = self.terminals.get(rpc.str(params, "terminalId")) orelse {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Unknown terminal"));
                        return;
                    };
                    // Bounded wait: the client stays single-threaded, so a
                    // command that never exits must not stall the app forever.
                    const deadline = c.SDL_GetTicks() + 5_000;
                    while (!terminal.reaped and c.SDL_GetTicks() < deadline) {
                        self.pumpTerminals();
                        c.SDL_Delay(1);
                    }
                    if (terminal.exit_code) |code| {
                        try self.sendOwned(try rpc.result(self.allocator, id, .{ .exitCode = code }));
                    } else {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32603, "Terminal still running"));
                    }
                } else if (std.mem.eql(u8, method, "terminal/kill")) {
                    if (!self.matchesSession(params)) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Invalid session"));
                        return;
                    }
                    const terminal = self.terminals.get(rpc.str(params, "terminalId")) orelse {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Unknown terminal"));
                        return;
                    };
                    _ = c.SDL_KillProcess(terminal.process, true);
                    try self.sendOwned(try rpc.result(self.allocator, id, .{}));
                } else if (std.mem.eql(u8, method, "terminal/release")) {
                    if (!self.matchesSession(params)) {
                        try self.sendOwned(try rpc.failure(self.allocator, id, -32602, "Invalid session"));
                        return;
                    }
                    self.closeTerminal(rpc.str(params, "terminalId"));
                    try self.sendOwned(try rpc.result(self.allocator, id, .{}));
                } else {
                    try self.sendOwned(try rpc.failure(self.allocator, id, -32601, "Client method not supported"));
                }
            },
        }
    }

    fn matchesSession(self: *const Client, params: rpc.Value) bool {
        return if (self.session_id) |id| std.mem.eql(u8, id, rpc.str(params, "sessionId")) else false;
    }

    pub fn permissionTitle(self: *const Client) []const u8 {
        const permission = self.permission orelse return "";
        const params = rpc.field(permission.parsed.value, "params") orelse return "";
        const tool = rpc.field(params, "toolCall") orelse return "Permission request";
        return rpc.str(tool, "title");
    }

    pub fn answerPermission(self: *Client, allow: bool) !void {
        const permission = self.permission orelse return;
        const value = permission.parsed.value;
        const params = rpc.field(value, "params").?;
        const options = rpc.field(params, "options").?;
        var selected: ?[]const u8 = null;
        for (options.array.items) |option| {
            const desired = if (allow) "allow_once" else "reject_once";
            if (std.mem.eql(u8, rpc.str(option, "kind"), desired)) {
                const id = rpc.str(option, "optionId");
                if (id.len != 0) selected = id;
                break;
            }
        }
        const id = rpc.field(value, "id").?;
        if (selected) |option_id| {
            try self.sendOwned(try rpc.result(self.allocator, id, .{ .outcome = .{ .outcome = "selected", .optionId = option_id } }));
        } else {
            // Never substitute allow_always for allow_once.
            try self.sendOwned(try rpc.result(self.allocator, id, .{ .outcome = .{ .outcome = "cancelled" } }));
        }
        self.permission.?.parsed.deinit();
        self.permission = null;
        try self.append(if (allow and selected != null) "[Permission] Allowed once.\n" else "[Permission] Rejected or cancelled.\n");
    }

    fn freeOption(self: *Client, option: *ConfigOption) void {
        self.allocator.free(option.id);
        self.allocator.free(option.value);
        for (option.options.items) |value| self.allocator.free(value);
        option.options.deinit(self.allocator);
    }

    fn clearConfig(self: *Client) void {
        for (self.config.items) |*option| self.freeOption(option);
        self.config.clearRetainingCapacity();
    }

    fn parseConfigOption(self: *Client, item: rpc.Value) !?ConfigOption {
        const id = rpc.str(item, "id");
        const current = rpc.field(item, "currentValue") orelse return null;
        if (id.len == 0 or current != .string) return null;
        var option: ConfigOption = .{
            .id = try self.allocator.dupe(u8, id),
            .value = try self.allocator.dupe(u8, current.string),
        };
        errdefer self.freeOption(&option);
        if (rpc.field(item, "options")) |opts| {
            if (opts == .array) {
                for (opts.array.items) |value_item| {
                    const value_str = rpc.str(value_item, "value");
                    if (value_str.len == 0) continue;
                    try option.options.append(self.allocator, try self.allocator.dupe(u8, value_str));
                }
            }
        }
        return option;
    }

    fn parseConfigOptions(self: *Client, result: rpc.Value) !void {
        const list = rpc.field(result, "configOptions") orelse return;
        if (list != .array) return;
        for (list.array.items) |item| {
            var option = try self.parseConfigOption(item) orelse continue;
            errdefer self.freeOption(&option);
            try self.config.append(self.allocator, option);
        }
    }

    pub fn configValue(self: *const Client, config_id: []const u8) ?[]const u8 {
        for (self.config.items) |option| {
            if (std.mem.eql(u8, option.id, config_id)) return option.value;
        }
        return null;
    }

    pub fn setConfigOption(self: *Client, config_id: []const u8, value: []const u8) !void {
        if (self.state != .ready) return error.AgentNotReady;
        const id = self.next_id;
        self.next_id += 1;
        try self.sendOwned(try rpc.request(self.allocator, id, "session/set_config_option", .{
            .sessionId = self.session_id.?,
            .configId = config_id,
            .value = value,
        }));
        self.pending = .{ .id = id, .kind = .set_config, .deadline = c.SDL_GetTicks() + 30_000 };
    }

    /// Cycle a select config option to its next value, if it has any.
    pub fn cycleConfigOption(self: *Client, config_id: []const u8) !void {
        if (self.state != .ready) return error.AgentNotReady;
        for (self.config.items) |option| {
            if (!std.mem.eql(u8, option.id, config_id)) continue;
            if (option.options.items.len < 2) return;
            for (option.options.items, 0..) |value, i| {
                if (std.mem.eql(u8, value, option.value)) {
                    const next = option.options.items[(i + 1) % option.options.items.len];
                    return self.setConfigOption(config_id, next);
                }
            }
        }
    }

    /// Write the lane transcript to a file. Persistence is opt-in: nothing is
    /// written unless the caller invokes this explicitly.
    pub fn exportTranscript(self: *Client, path: []const u8) !void {
        try files.replace(self.allocator, path, self.transcript.items);
    }
};
