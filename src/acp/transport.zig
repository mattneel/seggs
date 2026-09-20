const std = @import("std");
const c = @import("native");
const Decoder = @import("framing.zig").Decoder;
const Allocator = std.mem.Allocator;

/// Bounded hand-off queue between the UI thread and one pipe worker.
/// The item and byte bounds are the backpressure contract: a producer that
/// outruns the worker fails with `QueueFull` instead of growing without limit.
/// Both bounds and the partial-write path are covered by native tests.
pub const Queue = struct {
    mutex: *c.SDL_Mutex,
    allocator: Allocator,
    items: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
    pub const max_items = 128;
    pub const max_bytes = 8 * 1024 * 1024;

    pub fn init(a: Allocator) !Queue {
        return .{ .allocator = a, .mutex = c.SDL_CreateMutex() orelse return error.SdlMutex };
    }
    pub fn deinit(self: *Queue) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
        c.SDL_DestroyMutex(self.mutex);
    }
    pub fn push(self: *Queue, owned: []u8) !void {
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        if (self.items.items.len >= max_items or self.bytes + owned.len > max_bytes) return error.QueueFull;
        try self.items.append(self.allocator, owned);
        self.bytes += owned.len;
    }
    pub fn pop(self: *Queue) ?[]u8 {
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        if (self.items.items.len == 0) return null;
        const item = self.items.orderedRemove(0);
        self.bytes -= item.len;
        return item;
    }
};

/// A byte sink for `writePacket`. The transport supplies an SDL stream sink; a
/// test supplies one that accepts short counts to exercise partial writes.
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) usize,
    notReady: *const fn (*anyopaque) bool,

    /// Accept as much as the sink takes right now. Zero means "retry later"
    /// only when `isNotReady` reports true.
    pub fn writeSome(self: Sink, bytes: []const u8) usize {
        return self.write(self.context, bytes);
    }

    pub fn isNotReady(self: Sink) bool {
        return self.notReady(self.context);
    }

    /// Sink over a nonblocking SDL stream, used by the pipe worker.
    pub fn stream(io: *c.SDL_IOStream) Sink {
        return .{ .context = @ptrCast(io), .write = streamWrite, .notReady = streamNotReady };
    }

    fn streamWrite(context: *anyopaque, bytes: []const u8) usize {
        const io: *c.SDL_IOStream = @ptrCast(@alignCast(context));
        const written = c.SDL_WriteIO(io, bytes.ptr, bytes.len);
        return if (written > 0) @intCast(written) else 0;
    }

    fn streamNotReady(context: *anyopaque) bool {
        const io: *c.SDL_IOStream = @ptrCast(@alignCast(context));
        return c.SDL_GetIOStatus(io) == c.SDL_IO_STATUS_NOT_READY;
    }
};

/// Push a packet through `sink`, tolerating short writes. `offset` advances by
/// whatever the sink accepted. Returns true once the packet is fully written;
/// false means the sink is not ready and the same offset should be retried.
/// A zero write that is not a not-ready condition is an I/O failure.
pub fn writePacket(packet: []const u8, offset: *usize, sink: Sink) !bool {
    while (offset.* < packet.len) {
        const written = sink.writeSome(packet[offset.*..]);
        if (written == 0) {
            if (sink.isNotReady()) return false;
            return error.TransportWrite;
        }
        offset.* += written;
    }
    return true;
}

/// One worker owns both nonblocking pipes for one process.
/// No JSON, editor, or GPU state crosses the thread boundary.
pub const Transport = struct {
    pub const Exit = enum(u8) { none, stopped, eof, io_error, protocol_limit, backpressure };
    allocator: Allocator,
    process: *c.SDL_Process,
    input: *c.SDL_IOStream,
    output: *c.SDL_IOStream,
    incoming: Queue,
    outgoing: Queue,
    worker: ?*c.SDL_Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    exit_code: std.atomic.Value(u8) = .init(@backingInt(Exit.none)),

    pub fn start(a: Allocator, argv: []const []const u8, cwd: []const u8) !*Transport {
        if (argv.len == 0) return error.EmptyCommand;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const args = try temp.alloc(?[*:0]const u8, argv.len + 1);
        for (argv, 0..) |arg, i| args[i] = (try temp.dupeSentinel(u8, arg, 0)).ptr;
        args[argv.len] = null;
        const cwd_z = try temp.dupeSentinel(u8, cwd, 0);
        const props = c.SDL_CreateProperties();
        if (props == 0) return error.SdlProperties;
        defer c.SDL_DestroyProperties(props);
        if (!c.SDL_SetPointerProperty(props, c.SDL_PROP_PROCESS_CREATE_ARGS_POINTER, @ptrCast(args.ptr)) or
            !c.SDL_SetStringProperty(props, c.SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, cwd_z.ptr) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, c.SDL_PROCESS_STDIO_APP) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, c.SDL_PROCESS_STDIO_APP) or
            !c.SDL_SetNumberProperty(props, c.SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, c.SDL_PROCESS_STDIO_INHERITED)) return error.SdlProperties;
        const process = c.SDL_CreateProcessWithProperties(props) orelse return error.AgentSpawn;
        errdefer {
            _ = c.SDL_KillProcess(process, true);
            _ = c.SDL_WaitProcess(process, true, null);
            c.SDL_DestroyProcess(process);
        }
        const input = c.SDL_GetProcessInput(process) orelse return error.AgentPipe;
        const output = c.SDL_GetProcessOutput(process) orelse return error.AgentPipe;
        const self = try a.create(Transport);
        errdefer a.destroy(self);
        var incoming = try Queue.init(a);
        errdefer incoming.deinit();
        var outgoing = try Queue.init(a);
        errdefer outgoing.deinit();
        self.* = .{ .allocator = a, .process = process, .input = input, .output = output, .incoming = incoming, .outgoing = outgoing };
        self.worker = c.SDL_CreateThread(workerMain, "seggs-acp", self) orelse return error.AgentThread;
        return self;
    }

    pub fn send(self: *Transport, json: []const u8) !void {
        if (self.exitReason() != .none) return error.AgentStopped;
        if (json.len > Decoder.max_frame_bytes) return error.FrameTooLarge;
        const packet = try self.allocator.alloc(u8, json.len + 1);
        errdefer self.allocator.free(packet);
        @memcpy(packet[0..json.len], json);
        packet[json.len] = '\n';
        try self.outgoing.push(packet);
    }

    /// The caller owns the result and must free it with allocator.
    pub fn receive(self: *Transport) ?[]u8 {
        return self.incoming.pop();
    }

    pub fn exitReason(self: *const Transport) Exit {
        return @fromBackingInt(@intCast(self.exit_code.load(.acquire)));
    }

    pub fn destroy(self: *Transport) void {
        self.stop_flag.store(true, .release);
        if (self.worker) |thread| c.SDL_WaitThread(thread, null);
        // Only the UI thread reaps the child, after the pipe worker exits.
        var status: c_int = 0;
        if (!c.SDL_WaitProcess(self.process, false, &status)) {
            _ = c.SDL_KillProcess(self.process, true);
            _ = c.SDL_WaitProcess(self.process, true, &status);
        }
        c.SDL_DestroyProcess(self.process);
        self.incoming.deinit();
        self.outgoing.deinit();
        const a = self.allocator;
        a.destroy(self);
    }

    fn workerMain(userdata: ?*anyopaque) callconv(.c) c_int {
        const self: *Transport = @ptrCast(@alignCast(userdata.?));
        const reason = self.run() catch |err| switch (err) {
            error.FrameTooLarge => Exit.protocol_limit,
            error.QueueFull => Exit.backpressure,
            else => Exit.io_error,
        };
        self.exit_code.store(@backingInt(reason), .release);
        return 0;
    }

    fn run(self: *Transport) !Exit {
        var decoder = Decoder.init(self.allocator);
        defer decoder.deinit();
        var pending: ?[]u8 = null;
        defer if (pending) |packet| self.allocator.free(packet);
        var offset: usize = 0;
        var buffer: [16 * 1024]u8 = undefined;
        const sink = Sink.stream(self.input);
        while (!self.stop_flag.load(.acquire)) {
            var progressed = false;
            if (pending == null) {
                pending = self.outgoing.pop();
                offset = 0;
            }
            if (pending) |packet| {
                const before = offset;
                const done = try writePacket(packet, &offset, sink);
                if (offset > before) progressed = true;
                if (done) {
                    self.allocator.free(packet);
                    pending = null;
                }
            }
            const count = c.SDL_ReadIO(self.output, &buffer, buffer.len);
            if (count > 0) {
                progressed = true;
                try decoder.feed(buffer[0..count]);
                while (try decoder.next()) |frame| {
                    if (frame.len == 0) {
                        self.allocator.free(frame);
                        continue;
                    }
                    self.incoming.push(frame) catch |err| {
                        self.allocator.free(frame);
                        return err;
                    };
                }
            } else {
                switch (c.SDL_GetIOStatus(self.output)) {
                    c.SDL_IO_STATUS_EOF => return if (decoder.buffer.items.len == 0) .eof else .io_error,
                    c.SDL_IO_STATUS_NOT_READY => {},
                    c.SDL_IO_STATUS_READY => {},
                    else => return .io_error,
                }
            }
            if (!progressed) c.SDL_Delay(2);
        }
        return .stopped;
    }
};
