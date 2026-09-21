const std = @import("std");
const c = @import("native");
const rpc = @import("protocol.zig");
const tool_call = @import("tool_call.zig");
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
    pub const State = enum {
        offline,
        initialize,
        new_session,
        ready,
        busy,
        cancelling,
        failed,

        /// Whether the lane is up at all. A harness that is working is up: it is
        /// the lane that is gone that is not, and calling a busy agent offline
        /// makes the interface disagree with what is plainly happening.
        pub fn up(self: State) bool {
            return switch (self) {
                .offline, .failed => false,
                else => true,
            };
        }

        pub fn label(self: State) []const u8 {
            return switch (self) {
                .offline, .failed => "OFFLINE",
                .ready => "READY",
                .initialize, .new_session => "STARTING",
                .busy, .cancelling => "WORKING",
            };
        }
    };
    const Request = struct { id: u64, kind: enum { initialize, authenticate, new_session, prompt, set_config }, deadline: u64 };
    /// An authentication method the harness says it accepts.
    pub const AuthMethod = struct { id: []u8, name: []u8 };
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

    /// ACP requires an absolute working directory, and a caller may hand in a
    /// relative one. It is resolved once, when the first session opens, and
    /// released with the client.
    session_cwd: ?[]u8 = null,
    permission: ?Permission = null,
    transcript: std.ArrayList(u8) = .empty,
    config: std.ArrayList(ConfigOption) = .empty,
    last_error: ?[]u8 = null,
    completed_turns: usize = 0,
    tool_events: usize = 0,
    /// Every line this lane has received, ever. Monotone, and deliberately not
    /// derived from the transcript: the transcript is capped and trims from the
    /// front, so its length stops moving while bytes are still arriving - and a
    /// reader watching for signs of life would see a working turn go quiet.
    updates: usize = 0,
    /// The tool calls a lane has seen, in arrival order. Each one knows the
    /// byte offset it belongs at, which is how the interface places a chip in
    /// the prose instead of the transcript carrying a line about it. Bounded by
    /// `tool_call.max_calls`, oldest dropped first, so a session that runs for
    /// hours cannot grow a list without bound.
    tool_calls: std.ArrayList(tool_call.ToolCall) = .empty,
    terminals: std.StringArrayHashMapUnmanaged(*Terminal) = .empty,
    terminal_counter: usize = 0,
    auth_methods: std.ArrayList(AuthMethod) = .empty,

    pub fn init(a: Allocator, preset: Agent, cwd: []const u8) Client {
        return .{ .allocator = a, .preset = preset, .cwd = preset.cwd orelse cwd };
    }

    pub fn deinit(self: *Client) void {
        self.stop();
        if (self.session_cwd) |cwd| self.allocator.free(cwd);
        self.session_cwd = null;
        self.clearToolCalls();
        self.tool_calls.deinit(self.allocator);
        self.transcript.deinit(self.allocator);
        self.clearAuth();
        self.auth_methods.deinit(self.allocator);
        self.clearConfig();
        self.config.deinit(self.allocator);
        if (self.last_error) |message| self.allocator.free(message);
    }

    pub fn append(self: *Client, bytes: []const u8) !void {
        // Bound transcript memory. Trim only at UTF-8 boundaries.
        const limit = 512 * 1024;
        if (bytes.len >= limit) {
            var trim_at = bytes.len - limit;
            while (trim_at < bytes.len and bytes[trim_at] & 0xc0 == 0x80) : (trim_at += 1) {}
            // Everything the buffer held, and the front of what is arriving,
            // leaves here. A recorded offset is a position in these same bytes,
            // so they move with the drop - before the bytes are appended, so a
            // call recorded at the end of the old transcript is moved too.
            tool_call.shiftAt(self.tool_calls.items, self.transcript.items.len + trim_at);
            self.transcript.clearRetainingCapacity();
            try self.transcript.appendSlice(self.allocator, bytes[trim_at..]);
            return;
        }
        if (self.transcript.items.len + bytes.len > limit) {
            var drop = self.transcript.items.len + bytes.len - limit;
            while (drop < self.transcript.items.len and self.transcript.items[drop] & 0xc0 == 0x80) : (drop += 1) {}
            const keep = self.transcript.items.len - drop;
            std.mem.copyForwards(u8, self.transcript.items[0..keep], self.transcript.items[drop..]);
            self.transcript.items.len = keep;
            // The front of the transcript is gone: every chip moves up with it,
            // and one that was nearer than the drop lands at the front.
            tool_call.shiftAt(self.tool_calls.items, drop);
        }
        try self.transcript.appendSlice(self.allocator, bytes);
    }

    /// Record a tool call. The chip the interface draws *is* the call, so a
    /// call that is read writes nothing into the transcript: the offset the
    /// record carries is the transcript's length as the call arrives, which is
    /// where the chip belongs - between the prose before it and the prose after
    /// it, in the order the calls happened.
    ///
    /// A call that cannot be read is the exception. There is no chip to draw
    /// for it, and a call that happened must still leave a trace, so it keeps
    /// the line the transcript used to carry for every call.
    fn recordToolCall(self: *Client, update: rpc.Value) !void {
        var parsed = tool_call.parse(self.allocator, update) catch |err| {
            // The allocator giving up is the client's problem rather than the
            // call's; a refusal of the call itself is not.
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try self.append("\n[Tool] ");
            try self.append(rpc.str(update, "title"));
            try self.append("\n");
            return;
        };
        // A failed merge leaves the record with its caller, so this is the
        // only release it needs.
        errdefer tool_call.deinit(&parsed, self.allocator);
        parsed.at = self.transcript.items.len;
        try self.updateToolCall(parsed);
    }

    /// The tool calls recorded so far, in arrival order. Each one knows the
    /// transcript offset it belongs at, which is where the interface places its
    /// chip.
    pub fn toolCalls(self: *const Client) []const tool_call.ToolCall {
        return self.tool_calls.items;
    }

    /// Store a call, or the update to one already stored. An update replaces
    /// the record with the same id in place, so a chip stays where it landed
    /// while the call it describes progresses; see `tool_call.merge`.
    pub fn updateToolCall(self: *Client, parsed: tool_call.ToolCall) !void {
        try tool_call.merge(&self.tool_calls, self.allocator, parsed);
    }

    fn clearToolCalls(self: *Client) void {
        for (self.tool_calls.items) |*call| tool_call.deinit(call, self.allocator);
        self.tool_calls.clearRetainingCapacity();
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

    /// Ask the harness for a session once authentication is done or unneeded.
    fn beginSession(self: *Client) !void {
        const next = self.next_id;
        self.next_id += 1;
        if (self.session_cwd == null) {
            self.session_cwd = files.realTarget(self.allocator, self.cwd) catch null;
        }
        const cwd = self.session_cwd orelse self.cwd;
        try self.sendOwned(try rpc.request(self.allocator, next, "session/new", .{ .cwd = cwd, .mcpServers = [0]struct {}{} }));
        self.pending = .{ .id = next, .kind = .new_session, .deadline = c.SDL_GetTicks() + 60_000 };
        self.state = .new_session;
    }

    fn beginAuthenticate(self: *Client, method: []const u8) !void {
        const next = self.next_id;
        self.next_id += 1;
        try self.sendOwned(try rpc.request(self.allocator, next, "authenticate", .{ .methodId = method }));
        self.pending = .{ .id = next, .kind = .authenticate, .deadline = c.SDL_GetTicks() + 120_000 };
        self.state = .initialize;
        try self.append("[ACP] Authenticating with ");
        try self.append(method);
        try self.append(".\n");
    }

    /// Remember the methods the harness accepts, so a login that needs a person
    /// can be reported with the names the harness uses.
    fn parseAuthMethods(self: *Client, result: rpc.Value) !void {
        self.clearAuth();
        const methods = rpc.field(result, "authMethods") orelse return;
        if (methods != .array) return;
        for (methods.array.items) |entry| {
            const id = rpc.str(entry, "id");
            if (id.len == 0 or id.len > 128) continue;
            const name = rpc.str(entry, "name");
            const owned_id = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(owned_id);
            const owned_name = try self.allocator.dupe(u8, if (name.len == 0) id else name);
            errdefer self.allocator.free(owned_name);
            try self.auth_methods.append(self.allocator, .{ .id = owned_id, .name = owned_name });
        }
    }

    fn clearAuth(self: *Client) void {
        for (self.auth_methods.items) |method| {
            self.allocator.free(method.id);
            self.allocator.free(method.name);
        }
        self.auth_methods.clearRetainingCapacity();
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
        self.updates += 1;
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
                    if (pending.kind != .prompt and self.auth_methods.items.len != 0) {
                        // A request that fails while the harness has named methods
                        // is the case a login would settle.
                        try self.append("\n[Authentication] The harness offers:");
                        for (self.auth_methods.items) |method| {
                            try self.append(" ");
                            try self.append(method.id);
                        }
                        try self.append(".\n");
                    }
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
                        try self.parseAuthMethods(result);
                        // A method named in the config is an explicit choice; a
                        // harness that needs a login without one reports the
                        // methods it offers instead of guessing.
                        if (self.preset.auth) |method| {
                            try self.beginAuthenticate(method);
                        } else {
                            try self.beginSession();
                        }
                    },
                    .authenticate => try self.beginSession(),
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
                    try self.recordToolCall(update);
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
    ///
    /// A file is not the panel. On screen a call is a chip the transcript does
    /// not spell out, and a file has no chips, so the records are written after
    /// the prose, one line each: an export that carried only the transcript
    /// would show an agent working with nothing saying what it did.
    pub fn exportTranscript(self: *Client, path: []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, self.transcript.items);
        if (self.tool_calls.items.len != 0) {
            try out.appendSlice(self.allocator, "\n[Calls]\n");
            for (self.tool_calls.items) |call| {
                try out.append(self.allocator, '[');
                try out.appendSlice(self.allocator, @tagName(call.kind));
                try out.appendSlice(self.allocator, "] ");
                try out.appendSlice(self.allocator, @tagName(call.state));
                if (call.subject.len != 0) {
                    try out.append(self.allocator, ' ');
                    try out.appendSlice(self.allocator, call.subject);
                }
                try out.append(self.allocator, '\n');
            }
        }
        try files.replace(self.allocator, path, out.items);
    }
};

test "a working harness is up, and only a gone one is not" {
    try std.testing.expect(Client.State.busy.up());
    try std.testing.expect(Client.State.ready.up());
    try std.testing.expect(!Client.State.offline.up());
    try std.testing.expect(!Client.State.failed.up());
    // The labels say what is happening rather than two states for three
    // situations: an agent that is mid-turn is neither ready nor gone.
    try std.testing.expectEqualStrings("WORKING", Client.State.busy.label());
    try std.testing.expectEqualStrings("READY", Client.State.ready.label());
    try std.testing.expectEqualStrings("OFFLINE", Client.State.failed.label());
}

/// A harness that never runs: these tests drive the transcript and the records
/// a lane keeps, and neither needs a process behind it.
fn testClient(a: std.mem.Allocator) Client {
    return Client.init(a, .{ .id = "test", .name = "Test", .argv = &.{"test-agent"} }, "/tmp");
}

fn parseUpdate(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(rpc.Value) {
    return std.json.parseFromSlice(rpc.Value, a, text, .{ .allocate = .alloc_always });
}

test "a tool call is a chip, not a line of the transcript" {
    const a = std.testing.allocator;
    var client = testClient(a);
    defer client.deinit();

    // What an agent said before the call, so the chip has prose to be placed
    // after rather than a transcript that starts with it.
    try client.append("AGENT > reading the app\n");

    const first = try parseUpdate(a,
        \\{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read file","kind":"read","status":"pending","locations":[{"path":"src/app.zig"}]}
    );
    defer first.deinit();
    try client.recordToolCall(first.value);
    try std.testing.expectEqual(@as(usize, 1), client.toolCalls().len);
    const call = client.toolCalls()[0];
    try std.testing.expectEqualStrings("t1", call.id);
    try std.testing.expectEqual(tool_call.Kind.read, call.kind);
    try std.testing.expectEqualStrings("src/app.zig", call.subject);
    // The offset is the transcript's length as the call arrived, which is where
    // the chip is drawn. The call is not text: neither its words nor the JSON
    // it arrived as are anywhere in the transcript.
    try std.testing.expectEqualStrings("AGENT > reading the app\n", client.transcript.items);
    try std.testing.expectEqual(client.transcript.items.len, call.at);
    try std.testing.expect(std.mem.indexOf(u8, client.transcript.items, "app.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, client.transcript.items, "toolCallId") == null);

    // An update as an agent writes one: the id and what changed, nothing else.
    // It writes nothing either, and the record keeps the offset it landed at,
    // so the chip does not move when the call progresses.
    const second = try parseUpdate(a,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed"}
    );
    defer second.deinit();
    try client.recordToolCall(second.value);
    try std.testing.expectEqual(@as(usize, 1), client.toolCalls().len);
    try std.testing.expectEqual(call.at, client.toolCalls()[0].at);
    try std.testing.expectEqual(tool_call.State.completed, client.toolCalls()[0].state);
    try std.testing.expectEqualStrings("src/app.zig", client.toolCalls()[0].subject);
    try std.testing.expectEqualStrings("AGENT > reading the app\n", client.transcript.items);

    // A call the reader cannot make sense of is still an event, and it never
    // takes the lane down with it: it has no chip, so it keeps its line.
    const refused = try parseUpdate(a,
        \\{"sessionUpdate":"tool_call","toolCallId":"t2","title":"A string is not a call","content":"not parts"}
    );
    defer refused.deinit();
    try client.recordToolCall(refused.value);
    try std.testing.expectEqual(@as(usize, 1), client.toolCalls().len);
    try std.testing.expect(std.mem.endsWith(u8, client.transcript.items, "\n[Tool] A string is not a call\n"));
}

test "an export says what the chips say, because a file has no chips" {
    const a = std.testing.allocator;
    var client = testClient(a);
    defer client.deinit();

    try client.append("AGENT > working\n");
    const reads = try parseUpdate(a,
        \\{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read file","kind":"read","status":"pending","locations":[{"path":"src/app.zig"}]}
    );
    defer reads.deinit();
    try client.recordToolCall(reads.value);
    const finished = try parseUpdate(a,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed"}
    );
    defer finished.deinit();
    try client.recordToolCall(finished.value);
    const runs = try parseUpdate(a,
        \\{"sessionUpdate":"tool_call","toolCallId":"t2","title":"Bash","kind":"execute","status":"failed","rawInput":{"command":"zig build test"}}
    );
    defer runs.deinit();
    try client.recordToolCall(runs.value);

    const path = try files.tempPath(a, "export", ".txt");
    defer a.free(path);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
    try client.exportTranscript(path);

    const written = try files.read(a, path, 64 * 1024);
    defer a.free(written);
    // The prose is what the transcript held, and the calls follow it in the
    // order they arrived, with the state each one reached.
    try std.testing.expectEqualStrings(
        \\AGENT > working
        \\
        \\[Calls]
        \\[read] completed src/app.zig
        \\[execute] failed zig build test
        \\
    , written);
}

test "a transcript that drops its front takes the recorded offsets with it" {
    const a = std.testing.allocator;
    var client = testClient(a);
    defer client.deinit();

    // A call that lands well into the transcript, so its offset has room to
    // move rather than only to clamp, and prose right before it, so there is
    // something to check the offset still points at the end of.
    const lead = try a.alloc(u8, 300 * 1024);
    defer a.free(lead);
    @memset(lead, 'l');
    try client.append(lead);
    const prose = "\nAGENT > reading the app\n";
    try client.append(prose);

    const frame = try parseUpdate(a,
        \\{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read file","kind":"read","status":"pending","locations":[{"path":"src/app.zig"}]}
    );
    defer frame.deinit();
    try client.recordToolCall(frame.value);
    const at = client.toolCalls()[0].at;
    try std.testing.expectEqual(lead.len + prose.len, at);

    // Enough filler to push the transcript past its bound by exactly a hundred
    // kilobytes: the offset moves up by that much, and the prose is still the
    // bytes immediately before it, which is where the chip is drawn.
    const limit = 512 * 1024;
    const drop = 100 * 1024;
    const filler = try a.alloc(u8, limit + drop - client.transcript.items.len);
    defer a.free(filler);
    @memset(filler, 'f');
    try client.append(filler);
    try std.testing.expectEqual(at - drop, client.toolCalls()[0].at);
    try std.testing.expect(std.mem.endsWith(u8, client.transcript.items[0 .. at - drop], prose));

    // A drop past every call left in the list lands them all at the front
    // rather than wrapping them somewhere in the middle of the prose.
    const flood = try a.alloc(u8, limit + 64 * 1024);
    defer a.free(flood);
    @memset(flood, 'z');
    try client.append(flood);
    try std.testing.expectEqual(@as(usize, 0), client.toolCalls()[0].at);
}
