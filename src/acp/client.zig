const std = @import("std");
const c = @import("native");
const rpc = @import("protocol.zig");
const Transport = @import("transport.zig").Transport;
const Agent = @import("../agents/registry.zig").Agent;
const Allocator = std.mem.Allocator;

pub const Client = struct {
    pub const State = enum { offline, initialize, new_session, ready, busy, cancelling, failed };
    const Request = struct { id: u64, kind: enum { initialize, new_session, prompt }, deadline: u64 };
    pub const Permission = struct { parsed: std.json.Parsed(rpc.Value) };
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
    last_error: ?[]u8 = null,
    completed_turns: usize = 0,
    tool_events: usize = 0,

    pub fn init(a: Allocator, preset: Agent, cwd: []const u8) Client {
        return .{ .allocator = a, .preset = preset, .cwd = preset.cwd orelse cwd };
    }

    pub fn deinit(self: *Client) void {
        self.stop();
        self.transcript.deinit(self.allocator);
        if (self.last_error) |message| self.allocator.free(message);
    }

    pub fn append(self: *Client, bytes: []const u8) !void {
        // Bound transcript memory. Trim only at UTF-8 boundaries.
        const limit = 512 * 1024;
        if (bytes.len >= limit) {
            self.transcript.clearRetainingCapacity();
            var start = bytes.len - limit;
            while (start < bytes.len and bytes[start] & 0xc0 == 0x80) : (start += 1) {}
            try self.transcript.appendSlice(self.allocator, bytes[start..]);
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
                .fs = .{ .readTextFile = false, .writeTextFile = false },
                .terminal = false,
            },
        }));
        self.pending = .{ .id = id, .kind = .initialize, .deadline = c.SDL_GetTicks() + 30_000 };
        try self.append("\n[ACP] Initialize. No filesystem or terminal capability advertised.\n");
    }

    pub fn stop(self: *Client) void {
        if (self.transport) |transport| transport.destroy();
        self.transport = null;
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
};
