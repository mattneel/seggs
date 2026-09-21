const std = @import("std");
const c = @import("native");
const rpc = @import("protocol.zig");
const tool_call = @import("tool_call.zig");
const stream = @import("stream.zig");
const image = @import("image.zig");
const plan = @import("plan.zig");
const session_state = @import("session_state.zig");
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
    /// Every run of reasoning, speech and compaction summary this lane has
    /// seen, in arrival order. A run is many chunks and one record, and like a
    /// tool call the record carries the transcript offset it belongs at - so
    /// reasoning is drawn where it happened rather than at the end. Bounded by
    /// `stream.max_streams`, oldest dropped first.
    stream_records: std.ArrayList(stream.Stream) = .empty,
    /// Every picture an agent has sent, in arrival order. An image part is not
    /// words and is not a run of them: it is a payload that has to be kept
    /// somewhere, so it is kept here, carrying the transcript offset it arrived
    /// at exactly as a call and a run do. Bounded by `image.max_images`, oldest
    /// dropped first.
    image_records: std.ArrayList(image.Image) = .empty,
    /// The plans an agent has reported, by id: what it says it is about to do.
    /// A plan is replaced whole by an update and taken away by a removal, so
    /// this is a set that moves rather than a history. Bounded by
    /// `plan.max_plans`, oldest dropped first.
    plan_records: std.ArrayList(plan.Plan) = .empty,
    /// How full the session's context is and what it has cost, as of the last
    /// `usage_update`: a count is the current count, not a history of counts.
    usage_stats: ?session_state.Usage = null,
    /// The compaction a session last reported, which is transient state rather
    /// than something a reader keeps: the summary itself is a stream.
    compaction_state: ?session_state.Compaction = null,
    /// The commands the agent accepts, replaced whole by each update.
    command_records: []session_state.Command = &.{},
    /// What the session calls itself, and when it was last active. Null means
    /// the session has not said, or has said to clear it.
    session_title: ?[]u8 = null,
    session_activity: ?[]u8 = null,
    /// The mode a session says it is in.
    current_mode: ?[]u8 = null,
    terminals: std.StringArrayHashMapUnmanaged(*Terminal) = .empty,
    terminal_counter: usize = 0,
    /// The handle the next run gets. It never repeats within a client, so an
    /// interface can name a run it has opened even after the transcript has
    /// trimmed its front and moved every offset in it.
    stream_counter: usize = 0,
    /// The handle the next picture gets, handed out for the same reason a run's
    /// is: a picture is drawn at an offset the transcript moves, and an
    /// interface that has to name one - a census line, a texture cache, a
    /// click - needs a handle that does not move.
    image_counter: usize = 0,
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
        self.clearStreams();
        self.stream_records.deinit(self.allocator);
        self.clearImages();
        self.image_records.deinit(self.allocator);
        self.clearPlans();
        self.plan_records.deinit(self.allocator);
        self.clearSessionState();
        self.transcript.deinit(self.allocator);
        self.clearAuth();
        self.auth_methods.deinit(self.allocator);
        self.clearConfig();
        self.config.deinit(self.allocator);
        if (self.last_error) |message| self.allocator.free(message);
    }

    /// Release everything a session said about itself: the counts, the
    /// compaction, the menu, the name and the mode. Each is replaced rather than
    /// accumulated, so this is the only place they are released.
    fn clearSessionState(self: *Client) void {
        if (self.usage_stats) |*counts| session_state.deinitUsage(counts, self.allocator);
        self.usage_stats = null;
        if (self.compaction_state) |*compaction| session_state.deinitCompaction(compaction, self.allocator);
        self.compaction_state = null;
        session_state.freeCommands(self.allocator, self.command_records);
        self.command_records = &.{};
        for ([_]*?[]u8{ &self.session_title, &self.session_activity, &self.current_mode }) |field| {
            if (field.*) |text| self.allocator.free(text);
            field.* = null;
        }
    }

    /// Move every recorded transcript offset up by the bytes that just left the
    /// front. Three kinds of record know an offset - a tool call, a run, and a
    /// picture - and they are shifted in one place so that a later reader
    /// cannot fix one and miss the others.
    fn shiftRecordOffsets(self: *Client, dropped: usize) void {
        tool_call.shiftAt(self.tool_calls.items, dropped);
        stream.shiftAt(self.stream_records.items, dropped);
        image.shiftAt(self.image_records.items, dropped);
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
            // call or a thought recorded at the end of the old transcript is
            // moved too.
            self.shiftRecordOffsets(self.transcript.items.len + trim_at);
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
            // The front of the transcript is gone: every recorded offset moves
            // up with it, and one that was nearer than the drop lands at the
            // front.
            self.shiftRecordOffsets(drop);
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

    fn clearStreams(self: *Client) void {
        for (self.stream_records.items) |*record| stream.deinit(record, self.allocator);
        self.stream_records.clearRetainingCapacity();
    }

    /// The pictures a lane has received, in arrival order. Each one knows the
    /// transcript offset it belongs at, which is where the interface draws it.
    pub fn images(self: *const Client) []const image.Image {
        return self.image_records.items;
    }

    fn clearImages(self: *Client) void {
        for (self.image_records.items) |*record| image.deinit(record, self.allocator);
        self.image_records.clearRetainingCapacity();
    }

    fn dropOldestImage(self: *Client) void {
        if (self.image_records.items.len <= image.max_images) return;
        var oldest = self.image_records.orderedRemove(0);
        image.deinit(&oldest, self.allocator);
    }

    /// Keep one image part. The record is placed at the transcript's length as
    /// the part arrived - the same rule a call and a run follow, so a picture is
    /// drawn between the prose before it and the prose after it - and it carries
    /// the next handle its lane hands out.
    ///
    /// A part this cannot keep is still a record: a picture that was refused is
    /// something a reader has to be able to see, and the refusal is what says
    /// which of the four things went wrong. Only a failure to allocate is the
    /// client's own problem rather than the part's.
    fn captureImage(self: *Client, content: rpc.Value) !void {
        self.image_counter += 1;
        var record = image.capture(self.allocator, content, self.transcript.items.len, self.image_counter) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer image.deinit(&record, self.allocator);
        try self.image_records.append(self.allocator, record);
        self.dropOldestImage();
    }

    /// Apply one `session/update`.
    ///
    /// Every update ACP defines is read here, and none of them is kept as the
    /// JSON it arrived as: a blob of protocol in a transcript is exactly what
    /// this reader exists to prevent. The fifteen kinds come to three shapes.
    /// What a session says is *happening* is a record with a transcript offset,
    /// so a reader meets it where it happened: a tool call (which is its own
    /// module, because it is the richest), and the three streams of text -
    /// reasoning, what the user said, a compaction summary. What a session says
    /// about *itself* replaces the last thing it said: usage, mode, title,
    /// commands, config, and the state of a compaction. And what it says it is
    /// about to do is a list that moves: the plans.
    ///
    /// A kind this does not know is not an error. Extension notifications are
    /// optional by the protocol's own words, and a client that dies on one is a
    /// client that cannot talk to tomorrow's agent.
    fn applyUpdate(self: *Client, update: rpc.Value) !void {
        const kind = rpc.str(update, "sessionUpdate");
        // A stream is a run of chunks with nothing in between, so a chunk of a
        // run continues it and every other update ends it. That is what makes
        // reasoning that started again after a tool call a second record placed
        // where it resumed, rather than a continuation drawn in the wrong place.
        if (std.mem.eql(u8, kind, "agent_thought_chunk")) return self.feedStream(.thought, update);
        if (std.mem.eql(u8, kind, "user_message_chunk")) return self.feedStream(.user, update);
        if (std.mem.eql(u8, kind, "compaction_summary_chunk")) return self.feedStream(.summary, update);
        stream.finishOpen(self.stream_records.items);
        if (std.mem.eql(u8, kind, "agent_message_chunk")) {
            // The agent speaking is the transcript: it is prose, and prose goes
            // where it is read.
            const content = rpc.field(update, "content") orelse return;
            const part = rpc.str(content, "type");
            if (std.mem.eql(u8, part, "text")) return self.append(rpc.str(content, "text"));
            // A picture in a message is a record placed where the message
            // arrived, not a line of prose: the interface draws it there, and
            // the words around it stay where the agent put them.
            if (image.isImage(content)) return self.captureImage(content);
            // A part that is neither words nor a picture - a resource link - has
            // no line in a transcript made of words, and it leaves the shape of
            // itself rather than nothing at all: a message with a link in it is
            // not a message with a gap in it.
            if (part.len == 0) return;
            try self.append("\n[");
            try self.append(part);
            try self.append(" part]\n");
        } else if (std.mem.eql(u8, kind, "tool_call") or std.mem.eql(u8, kind, "tool_call_update")) {
            self.tool_events += 1;
            try self.recordToolCall(update);
        } else if (std.mem.eql(u8, kind, "plan") or std.mem.eql(u8, kind, "plan_update") or std.mem.eql(u8, kind, "plan_removed")) {
            try self.updatePlans(update);
        } else if (std.mem.eql(u8, kind, "usage_update")) {
            try self.updateUsage(update);
        } else if (std.mem.eql(u8, kind, "compaction_update")) {
            try self.updateCompaction(update);
        } else if (std.mem.eql(u8, kind, "available_commands_update")) {
            try self.updateCommands(update);
        } else if (std.mem.eql(u8, kind, "config_option_update")) {
            // The same shape the session opened with, and the same reader: the
            // options a session has now are the options it just sent.
            self.clearConfig();
            try self.parseConfigOptions(update);
        } else if (std.mem.eql(u8, kind, "current_mode_update")) {
            try self.setMode(rpc.str(update, "currentModeId"));
        } else if (std.mem.eql(u8, kind, "session_info_update")) {
            try self.updateSessionInfo(update);
        }
        // Anything else is an extension notification, or a kind this version of
        // ACP does not have: optional, and ignored rather than fatal.
    }

    fn clearPlans(self: *Client) void {
        for (self.plan_records.items) |*record| plan.deinit(record, self.allocator);
        self.plan_records.clearRetainingCapacity();
    }

    /// Add one chunk to the run of its channel, opening a record where nothing
    /// is open. The record is placed at the transcript's length as the run
    /// begins, which is where the interface draws it: the reasoning happened
    /// there, and what the agent did about it comes after.
    ///
    /// A chunk that says nothing does not open a record - a turn that answered
    /// with a stray newline would otherwise grow one record that says nothing
    /// on every turn - and a run already at its bound keeps the record it has
    /// rather than opening another, so the rest of the stream cannot become a
    /// record per chunk.
    ///
    /// A run therefore opens on the first words of it: a part that carries no
    /// words is counted as a part of the run that is open, rather than opening
    /// a record that would have nothing in it to draw. A picture is the one part
    /// that is kept rather than counted: it becomes a record of its own, placed
    /// where it arrived, and it does not open a run because a run is words.
    fn feedStream(self: *Client, channel: stream.Channel, update: rpc.Value) !void {
        const content = rpc.field(update, "content") orelse return;
        if (image.isImage(content)) return self.captureImage(content);
        // A compaction names itself; a thought and a message do not, so the
        // run is the one that is open.
        const key = if (channel == .summary) rpc.str(update, "compactionId") else "";
        const index = stream.open(self.stream_records.items, channel, key) orelse opening: {
            if (stream.blank(stream.textOf(content))) return;
            // The run before this one is over, whatever kind it was: what
            // arrives next with nothing in between is a new run, and a record
            // that kept pulsing would say the agent is still thinking.
            stream.finishOpen(self.stream_records.items);
            self.stream_counter += 1;
            var record = try stream.begin(self.allocator, channel, key, self.transcript.items.len, self.stream_counter);
            errdefer stream.deinit(&record, self.allocator);
            try self.stream_records.append(self.allocator, record);
            self.dropOldestStream();
            break :opening self.stream_records.items.len - 1;
        };
        stream.feed(&self.stream_records.items[index], self.allocator, content) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The run has reached what it may hold, or one chunk carried more
            // than a chunk. Neither takes the lane down: the record keeps what
            // fits and says how much it left out.
            else => {},
        };
    }

    /// The record a compaction's finished summary belongs on, if one is already
    /// there: the chunks of a summary and the whole summary that replaces them
    /// are the same thing, so they share a record.
    fn summaryRecord(self: *Client, id: []const u8) ?usize {
        var index = self.stream_records.items.len;
        while (index > 0) {
            index -= 1;
            const record = self.stream_records.items[index];
            if (record.channel == .summary and std.mem.eql(u8, record.key, id)) return index;
        }
        return null;
    }

    fn dropOldestStream(self: *Client) void {
        if (self.stream_records.items.len <= stream.max_streams) return;
        var oldest = self.stream_records.orderedRemove(0);
        stream.deinit(&oldest, self.allocator);
    }

    /// Apply a `plan`, `plan_update` or `plan_removed`. A plan this reader
    /// cannot make sense of never takes the lane down with it, and there is no
    /// record to draw for it, so it keeps a line the way an unreadable call
    /// does.
    fn updatePlans(self: *Client, update: rpc.Value) !void {
        plan.apply(&self.plan_records, self.allocator, update) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try self.append("\n[Plan] An update this client could not read.\n"),
        };
    }

    /// Keep the latest usage. A count the reader cannot make sense of leaves the
    /// last one standing rather than replacing a true count with a wrong one.
    fn updateUsage(self: *Client, update: rpc.Value) !void {
        const parsed = session_state.parseUsage(self.allocator, update) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        if (self.usage_stats) |*counts| session_state.deinitUsage(counts, self.allocator);
        self.usage_stats = parsed;
    }

    fn updateCompaction(self: *Client, update: rpc.Value) !void {
        const parsed = session_state.parseCompaction(self.allocator, update) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        if (self.compaction_state) |*compaction| session_state.deinitCompaction(compaction, self.allocator);
        self.compaction_state = parsed;
        // A summary sent whole rather than in chunks goes where those chunks
        // would have: a compaction that never streams still has its summary in
        // the record, and one that did stream has it replaced rather than
        // doubled.
        const summary = rpc.field(update, "summary") orelse return;
        if (summary != .array or summary.array.items.len == 0) return;
        try self.recordSummary(self.compaction_state.?.id, summary.array.items);
    }

    fn recordSummary(self: *Client, id: []const u8, blocks: []const rpc.Value) !void {
        const index = self.summaryRecord(id) orelse opening: {
            // Whatever run was open is not this one, and it is over.
            stream.finishOpen(self.stream_records.items);
            self.stream_counter += 1;
            var record = try stream.begin(self.allocator, .summary, id, self.transcript.items.len, self.stream_counter);
            errdefer stream.deinit(&record, self.allocator);
            try self.stream_records.append(self.allocator, record);
            self.dropOldestStream();
            break :opening self.stream_records.items.len - 1;
        };
        stream.replace(&self.stream_records.items[index], self.allocator, blocks) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }

    /// Replace the menu of commands a session accepts. A menu this cannot read
    /// leaves the last one standing rather than leaving a reader with nothing to
    /// pick from.
    fn updateCommands(self: *Client, update: rpc.Value) !void {
        const parsed = session_state.parseCommands(self.allocator, update) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        session_state.freeCommands(self.allocator, self.command_records);
        self.command_records = parsed;
    }

    /// What a session calls itself. A field sent as null clears it and a field
    /// that is not sent at all is left alone: an update that carries a new title
    /// must not erase when the session was last active.
    fn updateSessionInfo(self: *Client, update: rpc.Value) !void {
        if (rpc.field(update, "title")) |title| try self.setOwned(&self.session_title, rpc.string(title) orelse "");
        if (rpc.field(update, "updatedAt")) |at| try self.setOwned(&self.session_activity, rpc.string(at) orelse "");
    }

    fn setMode(self: *Client, mode: []const u8) !void {
        try self.setOwned(&self.current_mode, mode);
    }

    /// Replace one of the strings a session says about itself. An empty value
    /// means nothing to say, which is what a cleared field and a field this
    /// cannot read both come to. So does a value past the bound: these are
    /// names and timestamps rather than content, and a name cut in half names
    /// nothing, so a value that long is not kept in part.
    fn setOwned(self: *Client, field: *?[]u8, value: []const u8) !void {
        if (field.*) |old| self.allocator.free(old);
        field.* = null;
        if (value.len == 0 or value.len > session_state.max_id_bytes) return;
        field.* = try self.allocator.dupe(u8, value);
    }

    /// The runs of reasoning, speech and summary a lane has seen, in arrival
    /// order. Each one knows the transcript offset it belongs at, which is where
    /// the interface draws it, and whether it is still arriving, which is what
    /// an interface pulses a label for.
    pub fn streams(self: *const Client) []const stream.Stream {
        return self.stream_records.items;
    }

    /// The plans a session has reported, by id.
    pub fn plans(self: *const Client) []const plan.Plan {
        return self.plan_records.items;
    }

    /// The latest usage a session reported: tokens in context, the size of the
    /// window, and what the session has cost.
    pub fn usage(self: *const Client) ?session_state.Usage {
        return self.usage_stats;
    }

    /// The compaction a session last reported, which is state rather than a
    /// record: what it is folding, and whether it worked.
    pub fn lastCompaction(self: *const Client) ?session_state.Compaction {
        return self.compaction_state;
    }

    /// The commands the agent accepts, which is what a reader picks from instead
    /// of typing blind.
    pub fn availableCommands(self: *const Client) []const session_state.Command {
        return self.command_records;
    }

    /// What the session calls itself, when it has said.
    pub fn sessionTitle(self: *const Client) ?[]const u8 {
        return self.session_title;
    }

    /// When the session was last active, as the agent timestamps it.
    pub fn sessionActivity(self: *const Client) ?[]const u8 {
        return self.session_activity;
    }

    /// The mode the session says it is in.
    pub fn currentMode(self: *const Client) ?[]const u8 {
        return self.current_mode;
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
                // The one capability this client has to earn rather than
                // announce. ACP sends an `image` part only to a client that
                // says it draws one, so a client that renders pictures and does
                // not say so is sent none and looks like it does nothing.
                // `src/acp/image.zig` is what keeps the claim true, and the two
                // other prompt capabilities are written out as `false` rather
                // than left off so that the three read as the one decision they
                // are: pictures are kept, audio and embedded resources are not
                // implemented and so are not claimed.
                .promptCapabilities = .{ .image = true, .audio = false, .embeddedContext = false },
            },
        }));
        self.pending = .{ .id = id, .kind = .initialize, .deadline = c.SDL_GetTicks() + 30_000 };
        try self.append("\n[ACP] Initialize. Filesystem, terminal and image capabilities advertised.\n");
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
        // A lane that is gone is not thinking, so nothing keeps pulsing. What
        // the run said stays: the record is history, the pulse is not.
        stream.finishOpen(self.stream_records.items);
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

    /// What an agent's terminal has printed so far, or null when no terminal has
    /// that id - which is what `terminal/release` leaves behind, since it frees
    /// the record.
    ///
    /// The caller gets the bytes rather than the record on purpose: the record's
    /// life is the command's, and what a reader sees of a command has to outlive
    /// it. The protocol says so - a client keeps displaying a terminal's output
    /// after the terminal is released - and the only way to do that is for
    /// whoever draws it to hold the screen, not the process. So this returns a
    /// borrow, the caller parses what it needs, and the caller's copy is what
    /// survives.
    pub fn terminalOutput(self: *const Client, id: []const u8) ?[]const u8 {
        if (id.len == 0) return null;
        const record = self.terminals.get(id) orelse return null;
        return record.buffer.items;
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
                        // The turn is over, so nothing is still arriving: a
                        // label that pulses after the agent stopped is telling a
                        // reader the agent is working when it is not.
                        stream.finishOpen(self.stream_records.items);
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
                try self.applyUpdate(update);
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
        if (id.len == 0) return null;
        // A select option holds the id of its value and a boolean holds a
        // boolean: both are a value a reader sets, so both are kept as the text
        // of one.
        const value = switch (current) {
            .string => |text| text,
            .bool => |flag| if (flag) "true" else "false",
            else => return null,
        };
        var option: ConfigOption = .{
            .id = try self.allocator.dupe(u8, id),
            .value = try self.allocator.dupe(u8, value),
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
    /// A file is not the panel. On screen a call is a chip and reasoning is a
    /// fold, and the transcript spells out neither, so the records are written
    /// after the prose, one line each: an export that carried only the
    /// transcript would show an agent working with nothing saying what it did,
    /// and would throw away the reasoning, which is the one thing in a session
    /// that exists nowhere else.
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
        if (self.stream_records.items.len != 0) {
            try out.appendSlice(self.allocator, "\n[Streams]\n");
            for (self.stream_records.items) |record| {
                try out.append(self.allocator, '[');
                try out.appendSlice(self.allocator, @tagName(record.channel));
                try out.appendSlice(self.allocator, "] ");
                try out.appendSlice(self.allocator, record.text);
                // A run the bound cut says so, the same way a bounded value in
                // a chip does: what is missing is not the same as what is not
                // there.
                if (record.truncated) {
                    var note: [64]u8 = undefined;
                    const written = try std.fmt.bufPrint(&note, " … ({d} bytes omitted)", .{record.dropped_bytes});
                    try out.appendSlice(self.allocator, written);
                }
                try out.append(self.allocator, '\n');
            }
        }
        if (self.plan_records.items.len != 0) {
            try out.appendSlice(self.allocator, "\n[Plan]\n");
            for (self.plan_records.items) |record| {
                switch (record.body) {
                    .entries => |entries| for (entries) |entry| {
                        try out.appendSlice(self.allocator, @tagName(entry.status));
                        try out.append(self.allocator, ' ');
                        try out.appendSlice(self.allocator, entry.content);
                        try out.append(self.allocator, '\n');
                    },
                    .markdown => |text| {
                        try out.appendSlice(self.allocator, text);
                        try out.append(self.allocator, '\n');
                    },
                    .file => |uri| {
                        try out.appendSlice(self.allocator, "plan in ");
                        try out.appendSlice(self.allocator, uri);
                        try out.append(self.allocator, '\n');
                    },
                }
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

/// One `session/update` as the notification it arrives in, driven through the
/// same reader the transport feeds: these tests are about the path a real
/// session takes rather than about a function called by hand.
fn notify(client: *Client, update: []const u8) !void {
    const line = try std.fmt.allocPrint(client.allocator,
        \\{{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"s1","update":{s}}}}}
    , .{update});
    defer client.allocator.free(line);
    try client.handle(line);
}

/// The lane these tests drive: a client with a session, since an update that
/// names another session is not the one a reader is looking at.
fn listeningClient(a: Allocator) !Client {
    var client = testClient(a);
    client.session_id = try a.dupe(u8, "s1");
    return client;
}

fn feedThought(client: *Client, a: Allocator, text: []const u8) !void {
    const update = try std.json.Stringify.valueAlloc(a, .{
        .sessionUpdate = "agent_thought_chunk",
        .content = .{ .type = "text", .text = text },
    }, .{});
    defer a.free(update);
    try notify(client, update);
}

test "reasoning arrives as chunks and leaves one record where it began" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    try client.append("AGENT > ");
    try notify(&client, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"The transcript \"}}");
    try notify(&client, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"throws thinking away.\"}}");
    try notify(&client, "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"I will fix that.\"}}");

    // One record, not one per chunk: a model reasons in hundreds of chunks, and
    // a transcript with hundreds of entries for one thought is not a
    // transcript.
    try std.testing.expectEqual(@as(usize, 1), client.streams().len);
    const record = client.streams()[0];
    try std.testing.expectEqual(stream.Channel.thought, record.channel);
    try std.testing.expectEqualStrings("The transcript throws thinking away.", record.text);
    try std.testing.expectEqual(@as(usize, 2), record.chunks);

    // Placed where the run began rather than where it ended: the reasoning
    // happened before the answer, and drawing it at the end would put the
    // reason after the conclusion.
    try std.testing.expectEqualStrings("AGENT > ", client.transcript.items[0..record.at]);
    try std.testing.expectEqualStrings("AGENT > I will fix that.", client.transcript.items);
    // The reasoning is a record and not prose, and none of the JSON either kind
    // arrived as is anywhere a reader can see it.
    try std.testing.expect(std.mem.indexOf(u8, client.transcript.items, "sessionUpdate") == null);

    // An update that is not a chunk of the run is what ends it: nothing is
    // still arriving, so nothing keeps pulsing.
    try std.testing.expect(!client.streams()[0].streaming);
}

test "a chunk that says nothing does not open a record" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    // A stray newline, an empty string, and a part with no text at all: none of
    // them is a thought, and a turn that grew a record for each would have a
    // transcript full of nothing. A picture is one of them - it is not words -
    // but it is kept rather than lost, so it is a record of its own rather than
    // a part of a run that never began.
    try notify(&client, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"\\n\\n\"}}");
    try notify(&client, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"\"}}");
    try notify(&client, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"image\",\"data\":\"aGk=\",\"mimeType\":\"image/png\"}}");
    try std.testing.expectEqual(@as(usize, 0), client.streams().len);
    try std.testing.expectEqual(@as(usize, 1), client.images().len);

    // A part that carries neither words nor a picture is still part of what the
    // agent sent, so the run that has one says how many it has rather than
    // being quietly short.
    try notify(&client, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Looking at \"}}");
    try notify(&client, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"resource_link\",\"uri\":\"file:///tmp/notes.md\",\"name\":\"notes\"}}");
    try std.testing.expectEqual(@as(usize, 1), client.streams().len);
    try std.testing.expectEqualStrings("Looking at ", client.streams()[0].text);
    try std.testing.expectEqual(@as(usize, 1), client.streams()[0].other_parts);
}

test "a run past what a run may hold keeps what fits and says what it dropped" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    const half = try a.alloc(u8, stream.max_stream_bytes / 2);
    defer a.free(half);
    @memset(half, 'r');
    try feedThought(&client, a, half);
    try feedThought(&client, a, half);
    try std.testing.expectEqual(stream.max_stream_bytes, client.streams()[0].text.len);
    try std.testing.expect(!client.streams()[0].truncated);

    // The chunk that does not fit is dropped rather than opening a second
    // record, or a stream past its bound would become one record per chunk -
    // which is the failure one record per stream exists to prevent.
    try feedThought(&client, a, half);
    try std.testing.expectEqual(@as(usize, 1), client.streams().len);
    try std.testing.expectEqual(stream.max_stream_bytes, client.streams()[0].text.len);
    try std.testing.expect(client.streams()[0].truncated);
    try std.testing.expectEqual(@as(usize, half.len), client.streams()[0].dropped_bytes);
}

test "a thought keeps its place when the transcript drops its front" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    // A run that lands well into the transcript, so its offset has room to move
    // rather than only to clamp, and prose right before it, so there is
    // something to check the offset still points at the end of.
    const lead = try a.alloc(u8, 300 * 1024);
    defer a.free(lead);
    @memset(lead, 'l');
    try client.append(lead);
    const prose = "\nAGENT > thinking about the widget\n";
    try client.append(prose);
    try feedThought(&client, a, "the widget draws records where they happened");
    const at = client.streams()[0].at;
    const seq = client.streams()[0].seq;
    try std.testing.expectEqual(lead.len + prose.len, at);
    try std.testing.expect(seq != 0);

    // Enough filler to push the transcript past its bound by exactly a hundred
    // kilobytes: the offset moves up by that much, which is where the reasoning
    // still belongs - the same rule a tool call's offset follows.
    const limit = 512 * 1024;
    const drop = 100 * 1024;
    const filler = try a.alloc(u8, limit + drop - client.transcript.items.len);
    defer a.free(filler);
    @memset(filler, 'f');
    try client.append(filler);
    try std.testing.expectEqual(at - drop, client.streams()[0].at);
    // The handle does not move with the offset: an interface that has this run
    // open is still looking at the same run after the transcript trimmed.
    try std.testing.expectEqual(seq, client.streams()[0].seq);
    try std.testing.expect(std.mem.endsWith(u8, client.transcript.items[0 .. at - drop], prose));

    // A drop past everything left lands the record at the front rather than
    // wrapping it into the middle of the prose.
    const flood = try a.alloc(u8, limit + 64 * 1024);
    defer a.free(flood);
    @memset(flood, 'z');
    try client.append(flood);
    try std.testing.expectEqual(@as(usize, 0), client.streams()[0].at);
}

test "what a session says about itself replaces the last thing it said" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    try notify(&client, "{\"sessionUpdate\":\"usage_update\",\"used\":1000,\"size\":200000,\"cost\":{\"amount\":0.5,\"currency\":\"USD\"}}");
    try std.testing.expectEqual(@as(u64, 1000), client.usage().?.used);
    try std.testing.expectEqualStrings("USD", client.usage().?.cost.?.currency);
    try notify(&client, "{\"sessionUpdate\":\"usage_update\",\"used\":4200,\"size\":200000}");
    try std.testing.expectEqual(@as(u64, 4200), client.usage().?.used);
    // A cost that came with one update and not with the next is not carried
    // over: what a reader sees is the last thing the session said.
    try std.testing.expectEqual(@as(?session_state.Cost, null), client.usage().?.cost);

    try notify(&client, "{\"sessionUpdate\":\"current_mode_update\",\"currentModeId\":\"plan\"}");
    try std.testing.expectEqualStrings("plan", client.currentMode().?);
    try notify(&client, "{\"sessionUpdate\":\"session_info_update\",\"title\":\"Overhaul the transcript\",\"updatedAt\":\"2026-09-21T10:00:00Z\"}");
    try std.testing.expectEqualStrings("Overhaul the transcript", client.sessionTitle().?);
    try std.testing.expectEqualStrings("2026-09-21T10:00:00Z", client.sessionActivity().?);
    // A field sent as null clears it, and a field the update did not carry is
    // left alone: a new title must not erase when the session was last active.
    try notify(&client, "{\"sessionUpdate\":\"session_info_update\",\"title\":null}");
    try std.testing.expectEqual(@as(?[]const u8, null), client.sessionTitle());
    try std.testing.expectEqualStrings("2026-09-21T10:00:00Z", client.sessionActivity().?);
    try std.testing.expectEqualStrings("plan", client.currentMode().?);

    try notify(&client, "{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":[{\"name\":\"compact\",\"description\":\"Fold the context\"}]}");
    try std.testing.expectEqual(@as(usize, 1), client.availableCommands().len);
    try std.testing.expectEqualStrings("compact", client.availableCommands()[0].name);
    try notify(&client, "{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":[{\"name\":\"help\",\"description\":\"Say what to do\"},{\"name\":\"clear\",\"description\":\"Start again\"}]}");
    try std.testing.expectEqual(@as(usize, 2), client.availableCommands().len);
    try std.testing.expectEqualStrings("help", client.availableCommands()[0].name);
}

test "a compaction is state and a summary is content" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    try notify(&client, "{\"sessionUpdate\":\"compaction_update\",\"compactionId\":\"c1\",\"status\":\"in_progress\"}");
    try std.testing.expectEqualStrings("c1", client.lastCompaction().?.id);
    try std.testing.expectEqual(session_state.Status.in_progress, client.lastCompaction().?.status);

    // A finished compaction that sends the summary whole rather than in chunks:
    // the summary is content, so it goes where its chunks would have gone
    // instead of being lost because nothing streamed it.
    try notify(&client, "{\"sessionUpdate\":\"compaction_update\",\"compactionId\":\"c1\",\"status\":\"completed\",\"summary\":[{\"type\":\"text\",\"text\":\"We were overhauling the transcript.\"}]}");
    try std.testing.expectEqual(session_state.Status.completed, client.lastCompaction().?.status);
    try std.testing.expectEqual(@as(usize, 1), client.streams().len);
    try std.testing.expectEqual(stream.Channel.summary, client.streams()[0].channel);
    try std.testing.expectEqualStrings("We were overhauling the transcript.", client.streams()[0].text);

    // A summary that arrived in chunks and then arrives whole is replaced rather
    // than doubled: the whole one is what the session says its summary is.
    try notify(&client, "{\"sessionUpdate\":\"compaction_summary_chunk\",\"compactionId\":\"c2\",\"content\":{\"type\":\"text\",\"text\":\"half a sum\"}}");
    try std.testing.expectEqual(@as(usize, 2), client.streams().len);
    try std.testing.expectEqualStrings("half a sum", client.streams()[1].text);
    try notify(&client, "{\"sessionUpdate\":\"compaction_update\",\"compactionId\":\"c2\",\"status\":\"completed\",\"summary\":[{\"type\":\"text\",\"text\":\"the whole summary\"}]}");
    try std.testing.expectEqual(@as(usize, 2), client.streams().len);
    try std.testing.expectEqualStrings("the whole summary", client.streams()[1].text);
    try std.testing.expectEqualStrings("c2", client.streams()[1].key);
}

test "a plan is a list that moves, not a line of JSON" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    try notify(&client, "{\"sessionUpdate\":\"plan\",\"entries\":[{\"content\":\"read the client\",\"priority\":\"high\",\"status\":\"in_progress\"},{\"content\":\"capture thoughts\",\"priority\":\"medium\",\"status\":\"pending\"}]}");
    try std.testing.expectEqual(@as(usize, 1), client.plans().len);
    try std.testing.expectEqual(@as(usize, 2), client.plans()[0].body.entries.len);
    try std.testing.expectEqualStrings("capture thoughts", client.plans()[0].body.entries[1].content);
    try std.testing.expectEqual(plan.Status.pending, client.plans()[0].body.entries[1].status);
    // The line this used to leave was the update's JSON, which is the thing
    // records exist to keep out of a transcript.
    try std.testing.expect(std.mem.indexOf(u8, client.transcript.items, "entries") == null);
    try std.testing.expect(std.mem.indexOf(u8, client.transcript.items, "sessionUpdate") == null);

    // A plan update moves one plan without disturbing another.
    try notify(&client, "{\"sessionUpdate\":\"plan_update\",\"plan\":{\"type\":\"items\",\"planId\":\"p1\",\"entries\":[{\"content\":\"draw it\",\"priority\":\"low\",\"status\":\"pending\"}]}}");
    try std.testing.expectEqual(@as(usize, 2), client.plans().len);
    try notify(&client, "{\"sessionUpdate\":\"plan_removed\",\"planId\":\"p1\"}");
    try std.testing.expectEqual(@as(usize, 1), client.plans().len);
    try std.testing.expectEqualStrings("", client.plans()[0].id);
}

test "an export carries the reasoning a file would otherwise lose" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    try client.append("AGENT > working\n");
    try notify(&client, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Think first.\"}}");
    try notify(&client, "{\"sessionUpdate\":\"plan\",\"entries\":[{\"content\":\"capture thoughts\",\"priority\":\"high\",\"status\":\"completed\"}]}");

    const path = try files.tempPath(a, "export-streams", ".txt");
    defer a.free(path);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
    try client.exportTranscript(path);

    const written = try files.read(a, path, 64 * 1024);
    defer a.free(written);
    // A file has no folds and no cards, so the records follow the prose: the
    // reasoning is the one thing in a session that exists nowhere else.
    try std.testing.expectEqualStrings(
        \\AGENT > working
        \\
        \\[Streams]
        \\[thought] Think first.
        \\
        \\[Plan]
        \\completed capture thoughts
        \\
    , written);
}

test "a run of another channel ends the run before it" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    try notify(&client, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Let me see.\"}}");
    try std.testing.expect(client.streams()[0].streaming);
    const thinking_at = client.streams()[0].at;

    // A user message is not a chunk of that run, and neither is a summary. The
    // reasoning stopped when the user spoke, so its label stops pulsing - and
    // the user has a record of their own, placed where they spoke rather than
    // merged into what the agent was thinking.
    try notify(&client, "{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Actually, do this instead.\"}}");
    try std.testing.expectEqual(@as(usize, 2), client.streams().len);
    try std.testing.expect(!client.streams()[0].streaming);
    try std.testing.expect(client.streams()[1].streaming);
    try std.testing.expectEqual(stream.Channel.user, client.streams()[1].channel);
    try std.testing.expectEqualStrings("Let me see.", client.streams()[0].text);
    try std.testing.expectEqualStrings("Actually, do this instead.", client.streams()[1].text);
    try std.testing.expect(client.streams()[1].at >= thinking_at);
}

test "a picture in a message is a record and any other part leaves a marker" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    // A picture in a message is not a line of prose: it is a record placed where
    // the message arrived, and the transcript keeps the words around it. A
    // record that could not be kept is still a record - the two bytes here are
    // not a PNG - because a reader has to be told which of the four things went
    // wrong rather than finding a gap where a picture was.
    try notify(&client, "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"image\",\"data\":\"aGk=\",\"mimeType\":\"image/png\"}}");
    try std.testing.expectEqualStrings("", client.transcript.items);
    try std.testing.expectEqual(@as(usize, 1), client.images().len);
    try std.testing.expectEqual(image.Refusal.not_an_image, client.images()[0].refusal);
    try std.testing.expectEqualStrings("image/png", client.images()[0].mime);
    // A part with no type at all carries nothing to mark.
    try notify(&client, "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{}}");
    try std.testing.expectEqualStrings("", client.transcript.items);
    // A part that is neither words nor a picture still leaves the shape of
    // itself: a message with a link in it is not a message with a gap in it.
    try notify(&client, "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"resource_link\",\"uri\":\"file:///tmp/notes.md\",\"name\":\"notes\"}}");
    try std.testing.expectEqualStrings("\n[resource_link part]\n", client.transcript.items);
    try notify(&client, "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"and prose still reads.\"}}");
    try std.testing.expectEqualStrings("\n[resource_link part]\nand prose still reads.", client.transcript.items);
}

test "a picture is kept where it arrived, with a handle and its bounds" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    try client.append("AGENT > look\n");
    var fixture: [512]u8 = undefined;
    const part = try std.fmt.bufPrint(&fixture, "{{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/png\"}}}}", .{image.sample_png_base64});
    try notify(&client, part);

    // Placed at the transcript's length as the part arrived - the same offset a
    // call and a run carry - and named by a handle of its own, because the
    // offset moves when the transcript trims and a cache key cannot.
    try std.testing.expectEqual(@as(usize, 1), client.images().len);
    try std.testing.expectEqual(client.transcript.items.len, client.images()[0].at);
    try std.testing.expectEqual(@as(usize, 1), client.images()[0].seq);
    try std.testing.expectEqual(image.Format.png, client.images()[0].format.?);
    // A picture writes nothing into the transcript: the words around it are the
    // words the agent sent.
    try std.testing.expectEqualStrings("AGENT > look\n", client.transcript.items);

    // The handles are handed out one at a time and never repeat, which is what
    // lets an interface name a picture it has already drawn.
    try notify(&client, part);
    try std.testing.expectEqual(@as(usize, 2), client.images()[1].seq);

    // Bounded like every other record: a session that sends more than the bound
    // keeps the newest images and drops the oldest, rather than growing a list a
    // session's length.
    for (0..image.max_images) |_| try notify(&client, part);
    try std.testing.expectEqual(image.max_images, client.images().len);
    try std.testing.expectEqual(@as(usize, 3), client.images()[0].seq);
}

test "a picture keeps its place when the transcript drops its front" {
    const a = std.testing.allocator;
    var client = try listeningClient(a);
    defer client.deinit();

    const lead = try a.alloc(u8, 300 * 1024);
    defer a.free(lead);
    @memset(lead, 'l');
    try client.append(lead);
    var fixture: [512]u8 = undefined;
    const part = try std.fmt.bufPrint(&fixture, "{{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/png\"}}}}", .{image.sample_png_base64});
    try notify(&client, part);
    const at = client.images()[0].at;
    try std.testing.expectEqual(lead.len, at);

    const limit = 512 * 1024;
    const drop = 100 * 1024;
    const filler = try a.alloc(u8, limit + drop - client.transcript.items.len);
    defer a.free(filler);
    @memset(filler, 'f');
    try client.append(filler);
    // The offset moves up with the bytes that left, which is where the picture
    // still belongs; the handle does not move with it.
    try std.testing.expectEqual(at - drop, client.images()[0].at);
    try std.testing.expectEqual(@as(usize, 1), client.images()[0].seq);
}
