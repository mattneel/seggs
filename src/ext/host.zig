const std = @import("std");
const quickjs = @import("quickjs");
const files = @import("../platform/files.zig");

const qc = quickjs.c;

/// Extension host: embeds a QuickJS-NG runtime and exposes the `seggs` API
/// to JavaScript extensions. Extensions call into the core through `seggs`.
///
/// The host is reached from callbacks via a thread-local (single-threaded
/// app), matching the jzs pattern. Never store `&self` in the JS context:
/// `Host` is returned by value, so a stack address would dangle.
pub const Host = struct {
    /// Subscriptions allowed across all extensions.
    pub const max_handlers = 32;

    const Handler = struct { event: []const u8, callback: quickjs.Value };

    /// One loaded extension: its own JavaScript runtime, the panels and
    /// subscriptions it registered, and the message from the last failure.
    pub const Extension = struct {
        /// Bundle file name, which is what diagnostics and reloads key on.
        name: []u8,
        ctx: *quickjs.Context,
        rt: *quickjs.Runtime,
        panels: std.StringArrayHashMapUnmanaged(quickjs.Value) = .empty,
        handlers: std.ArrayListUnmanaged(Handler) = .empty,
        /// Why the bundle failed to load, or empty when it loaded.
        problem: std.ArrayListUnmanaged(u8) = .empty,

        pub fn ok(self: *const Extension) bool {
            return self.problem.items.len == 0;
        }

        fn deinit(self: *Extension, a: std.mem.Allocator) void {
            for (self.panels.keys()) |key| a.free(key);
            for (self.panels.values()) |value| value.deinit(self.ctx);
            self.panels.deinit(a);
            for (self.handlers.items) |entry| {
                a.free(entry.event);
                entry.callback.deinit(self.ctx);
            }
            self.handlers.deinit(a);
            self.problem.deinit(a);
            self.ctx.deinit();
            self.rt.deinit();
            a.free(self.name);
            a.destroy(self);
        }
    };

    /// Something an extension asked the interface to do.
    pub const Action = struct {
        /// One of `ActionOp`.
        op: ActionOp,
        /// Identifier the request named, owned by the host until taken.
        id: []const u8,
    };

    pub const ActionOp = enum { start, stop, activate, open, switch_buffer, sidebar, prompt, quick_open };

    /// Actions allowed to queue between frames.
    pub const max_actions = 32;

    allocator: std.mem.Allocator,
    /// Loaded extensions, in load order. A failed bundle stays in the list with
    /// its message, because that message is what an extension author, or an
    /// agent writing one, needs to read.
    extensions: std.ArrayListUnmanaged(*Extension) = .empty,
    /// Incremented on every reload, so a caller can tell that registration may
    /// have changed under it.
    generation: usize = 0,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    /// State the interface shows, as JSON, replaced by the app each frame. It is
    /// kept as text because each extension parses it in its own context.
    snapshot: std.ArrayListUnmanaged(u8) = .empty,
    /// Actions extensions asked for, applied by the app between frames. An
    /// extension never reaches into the interface directly: it asks, and the
    /// frame that is being drawn is left alone.
    actions: std.ArrayListUnmanaged(Action) = .empty,

    /// The extension a callback is running for, and the host it belongs to.
    threadlocal var current: ?*Host = null;
    threadlocal var current_extension: ?*Extension = null;

    pub fn init(a: std.mem.Allocator) Host {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Host) void {
        if (current == self) current = null;
        self.unload();
        self.extensions.deinit(self.allocator);
        self.snapshot.deinit(self.allocator);
        for (self.actions.items) |action| self.allocator.free(action.id);
        self.actions.deinit(self.allocator);
    }

    /// Drop every extension. Their contexts go with them, so nothing an
    /// extension registered outlives its bundle.
    pub fn unload(self: *Host) void {
        for (self.extensions.items) |extension| extension.deinit(self.allocator);
        self.extensions.clearRetainingCapacity();
        self.generation += 1;
    }

    /// Latest status message written by an extension via `seggs.status`.
    pub fn status(self: *Host) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    fn setStatus(self: *Host, msg: []const u8) void {
        const n = @min(msg.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], msg[0..n]);
        self.status_len = n;
    }

    /// Install the `seggs` API in one extension's context.
    fn installApi(extension: *Extension) !void {
        const ctx = extension.ctx;
        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);
        // setPropertyStr takes ownership of the value, so the `seggs` object is
        // owned by the global after this call — do NOT deinit it here.
        const seggs = quickjs.Value.initObject(ctx);
        try seggs.setPropertyStr(ctx, "version", quickjs.Value.initCFunction2(ctx, versionFn, "version", 0, .generic, 0));
        try seggs.setPropertyStr(ctx, "status", quickjs.Value.initCFunction2(ctx, statusFn, "status", 1, .generic, 0));
        const ui = quickjs.Value.initObject(ctx);
        try ui.setPropertyStr(ctx, "panel", quickjs.Value.initCFunction2(ctx, panelFn, "panel", 2, .generic, 0));
        try ui.setPropertyStr(ctx, "on", quickjs.Value.initCFunction2(ctx, onFn, "on", 2, .generic, 0));
        try seggs.setPropertyStr(ctx, "ui", ui);
        const agent = quickjs.Value.initObject(ctx);
        try agent.setPropertyStr(ctx, "action", quickjs.Value.initCFunction2(ctx, agentActionFn, "action", 2, .generic, 0));
        try seggs.setPropertyStr(ctx, "agent", agent);
        const editor = quickjs.Value.initObject(ctx);
        try editor.setPropertyStr(ctx, "action", quickjs.Value.initCFunction2(ctx, editorActionFn, "action", 2, .generic, 0));
        try seggs.setPropertyStr(ctx, "editor", editor);
        const app_actions = quickjs.Value.initObject(ctx);
        try app_actions.setPropertyStr(ctx, "action", quickjs.Value.initCFunction2(ctx, appActionFn, "action", 1, .generic, 0));
        try seggs.setPropertyStr(ctx, "app", app_actions);
        const extensions = quickjs.Value.initObject(ctx);
        try extensions.setPropertyStr(ctx, "list", quickjs.Value.initCFunction2(ctx, extensionsFn, "list", 0, .generic, 0));
        try seggs.setPropertyStr(ctx, "extensions", extensions);
        try seggs.setPropertyStr(ctx, "snapshot", quickjs.Value.initCFunction2(ctx, snapshotFn, "snapshot", 0, .generic, 0));
        try global.setPropertyStr(ctx, "seggs", seggs);
    }

    /// Read every `*.js` bundle in `dir`, replacing whatever is loaded. A bundle
    /// that throws stays in the list with its message, so a reload after a failed
    /// edit reports the failure rather than silently dropping the extension.
    pub fn loadExtensions(self: *Host, dir: []const u8) usize {
        self.unload();
        var paths: std.ArrayList([]u8) = .empty;
        defer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }
        files.listMatching(self.allocator, dir, ".js", &paths);
        var loaded: usize = 0;
        for (paths.items) |path| {
            const extension = self.loadOne(path) catch |err| {
                std.log.err("extension {s}: {s}", .{ path, @errorName(err) });
                continue;
            };
            if (extension.ok()) {
                loaded += 1;
            } else {
                std.log.err("extension {s}: {s}", .{ extension.name, extension.problem.items });
            }
        }
        return loaded;
    }

    fn loadOne(self: *Host, path: []const u8) !*Extension {
        const raw = try files.read(self.allocator, path, 1 << 20);
        defer self.allocator.free(raw);
        // The engine's lexer reads past the last byte it was given, so the
        // bundle is copied into a zeroed buffer with slack: without it the
        // meaning of a bundle depends on whatever the allocator left behind the
        // source, and a bundle that is correct fails to parse. The allocation
        // is aligned as well, since the lexer scans in machine words.
        const source = try self.allocator.alignedAlloc(u8, .of(u64), raw.len + 8);
        defer self.allocator.free(source);
        @memset(source, 0);
        @memcpy(source[0..raw.len], raw);
        const bundle = source[0..raw.len];
        const name = try self.allocator.dupe(u8, std.fs.path.basename(path));
        errdefer self.allocator.free(name);
        const rt = try quickjs.Runtime.init();
        errdefer rt.deinit();
        const ctx = try quickjs.Context.init(rt);
        errdefer ctx.deinit();
        const extension = try self.allocator.create(Extension);
        extension.* = .{ .name = name, .ctx = ctx, .rt = rt };
        errdefer {
            extension.panels.deinit(self.allocator);
            extension.handlers.deinit(self.allocator);
            extension.problem.deinit(self.allocator);
            ctx.deinit();
            rt.deinit();
            self.allocator.free(name);
            self.allocator.destroy(extension);
        }
        current = self;
        current_extension = extension;
        try installApi(extension);
        const filename = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(filename);
        const result = ctx.eval(bundle, filename, .{});
        defer result.deinit(ctx);
        if (result.isException()) {
            // Reading the exception clears it, and its message is what an author
            // or an agent needs in order to fix the bundle.
            const exception = ctx.getException();
            defer exception.deinit(ctx);
            if (exception.toCString(ctx)) |message| {
                defer ctx.freeCString(message);
                try extension.problem.appendSlice(self.allocator, std.mem.span(message));
            }
        }
        try self.extensions.append(self.allocator, extension);
        return extension;
    }

    /// Every extension with its load state, as JSON. This is what a reload
    /// reports and what an author or an agent reads to find out what happened.
    pub fn diagnostics(self: *Host, a: std.mem.Allocator) ![]u8 {
        const Report = struct { name: []const u8, loaded: bool, problem: []const u8, panels: usize };
        const reports = try a.alloc(Report, self.extensions.items.len);
        defer a.free(reports);
        for (self.extensions.items, reports) |extension, *report| {
            report.* = .{
                .name = extension.name,
                .loaded = extension.ok(),
                .problem = extension.problem.items,
                .panels = extension.panels.count(),
            };
        }
        return std.json.Stringify.valueAlloc(a, .{
            .generation = self.generation,
            .loaded = self.loadedCount(),
            .extensions = reports,
        }, .{});
    }

    /// The first bundle that failed, so a reload can say why in the interface
    /// rather than only in the report file.
    pub fn firstProblem(self: *const Host) ?struct { name: []const u8, problem: []const u8 } {
        for (self.extensions.items) |extension| {
            if (extension.ok()) continue;
            return .{ .name = extension.name, .problem = extension.problem.items };
        }
        return null;
    }

    fn loadedCount(self: *const Host) usize {
        var count: usize = 0;
        for (self.extensions.items) |extension| {
            if (extension.ok()) count += 1;
        }
        return count;
    }

    /// Ask a registered panel for a description, as JSON text. Returns null when
    /// no panel is registered under the name, when it throws, or when it returns
    /// something that cannot be serialized.
    ///
    /// The provider runs in the context of the extension that registered it, and
    /// is told the size of the region it fills, because a panel showing a list
    /// has to know how many rows fit.
    pub fn panelDescription(self: *Host, name: []const u8, width: f32, height: f32) !?[]u8 {
        for (self.extensions.items) |extension| {
            if (!extension.ok()) continue;
            const provider = extension.panels.get(name) orelse continue;
            const ctx = extension.ctx;
            current = self;
            current_extension = extension;
            const global = ctx.getGlobalObject();
            defer global.deinit(ctx);
            const arguments = [_]quickjs.Value{
                quickjs.Value.initNumber(ctx, width),
                quickjs.Value.initNumber(ctx, height),
            };
            defer quickjs.Value.deinitMany(ctx, &arguments);
            const result = provider.call(ctx, global, &arguments);
            defer result.deinit(ctx);
            if (result.isException()) {
                const exception = ctx.getException();
                defer exception.deinit(ctx);
                return null;
            }
            const json = qc.JS_JSONStringify(ctx.cval(), result.cval(), quickjs.Value.undefined.cval(), quickjs.Value.undefined.cval());
            const value = quickjs.Value.fromCVal(json);
            defer value.deinit(ctx);
            const text = value.toCString(ctx) orelse return null;
            defer ctx.freeCString(text);
            return try self.allocator.dupe(u8, std.mem.span(text));
        }
        return null;
    }

    /// Call the handler each extension registered for an interface event. The
    /// argument describes what happened; an extension that throws is reported
    /// and ignored, so one bad extension cannot stop the interface.
    pub fn dispatch(self: *Host, event: []const u8, fields: anytype) void {
        const info = @typeInfo(@TypeOf(fields)).@"struct";
        for (self.extensions.items) |extension| {
            if (!extension.ok()) continue;
            var handled = false;
            for (extension.handlers.items) |entry| {
                if (std.mem.eql(u8, entry.event, event)) handled = true;
            }
            if (!handled) continue;
            const ctx = extension.ctx;
            current = self;
            current_extension = extension;
            const global = ctx.getGlobalObject();
            defer global.deinit(ctx);
            const argument = quickjs.Value.initObject(ctx);
            defer argument.deinit(ctx);
            // setPropertyStr consumes the value, so a rejected one is freed here
            // rather than leaked.
            inline for (info.field_names, info.field_types) |name, FieldType| {
                const value = @field(fields, name);
                if (FieldType == []const u8) {
                    argument.setPropertyStr(ctx, name, quickjs.Value.initStringLen(ctx, value)) catch |err| {
                        std.log.err("event {s}: {s}", .{ event, @errorName(err) });
                    };
                } else if (FieldType == f32 or FieldType == i32 or FieldType == usize) {
                    const number: f64 = switch (FieldType) {
                        f32 => value,
                        else => @floatFromInt(value),
                    };
                    argument.setPropertyStr(ctx, name, quickjs.Value.initNumber(ctx, number)) catch |err| {
                        std.log.err("event {s}: {s}", .{ event, @errorName(err) });
                    };
                }
            }
            for (extension.handlers.items) |entry| {
                if (!std.mem.eql(u8, entry.event, event)) continue;
                const result = entry.callback.call(ctx, global, &.{argument});
                defer result.deinit(ctx);
                if (result.isException()) {
                    const exception = ctx.getException();
                    defer exception.deinit(ctx);
                    if (exception.toCString(ctx)) |message| {
                        defer ctx.freeCString(message);
                        std.log.err("extension {s} {s} handler: {s}", .{ extension.name, event, std.mem.span(message) });
                    }
                }
            }
        }
    }

    fn extensionsFn(ctx: ?*quickjs.Context, _: quickjs.Value, _: []const qc.JSValue) quickjs.Value {
        const q = ctx orelse return quickjs.Value.undefined;
        const host = current orelse return quickjs.Value.undefined;
        const text = host.diagnostics(host.allocator) catch return quickjs.Value.undefined;
        defer host.allocator.free(text);
        return parseJsonIn(q, text);
    }

    /// Parse JSON text in one context, since a value belongs to the context that
    /// created it.
    fn parseJsonIn(ctx: *quickjs.Context, text: []const u8) quickjs.Value {
        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);
        const parse = global.getPropertyStr(ctx, "JSON");
        defer parse.deinit(ctx);
        const parse_fn = parse.getPropertyStr(ctx, "parse");
        defer parse_fn.deinit(ctx);
        const string = quickjs.Value.initStringLen(ctx, text);
        defer string.deinit(ctx);
        const value = parse_fn.call(ctx, parse, &.{string});
        if (value.isException()) {
            const exception = ctx.getException();
            defer exception.deinit(ctx);
            return quickjs.Value.undefined;
        }
        return value;
    }

    fn onFn(ctx: ?*quickjs.Context, _: quickjs.Value, args: []const qc.JSValue) quickjs.Value {
        const q = ctx orelse return quickjs.Value.undefined;
        const host = current orelse return quickjs.Value.undefined;
        const extension = current_extension orelse return quickjs.Value.undefined;
        if (args.len < 2) return quickjs.Value.undefined;
        const name = quickjs.Value.fromCVal(args[0]).toCString(q) orelse return quickjs.Value.undefined;
        defer q.freeCString(name);
        host.registerHandler(extension, std.mem.span(name), quickjs.Value.fromCVal(args[1])) catch |err| {
            std.log.err("handler {s} not registered: {s}", .{ std.mem.span(name), @errorName(err) });
        };
        return quickjs.Value.undefined;
    }

    fn panelFn(ctx: ?*quickjs.Context, _: quickjs.Value, args: []const qc.JSValue) quickjs.Value {
        const q = ctx orelse return quickjs.Value.undefined;
        const host = current orelse return quickjs.Value.undefined;
        const extension = current_extension orelse return quickjs.Value.undefined;
        if (args.len < 2) return quickjs.Value.undefined;
        const name = quickjs.Value.fromCVal(args[0]).toCString(q) orelse return quickjs.Value.undefined;
        defer q.freeCString(name);
        host.registerPanel(extension, std.mem.span(name), quickjs.Value.fromCVal(args[1])) catch |err| {
            std.log.err("panel {s} not registered: {s}", .{ std.mem.span(name), @errorName(err) });
        };
        return quickjs.Value.undefined;
    }

    fn statusFn(ctx: ?*quickjs.Context, _: quickjs.Value, args: []const qc.JSValue) quickjs.Value {
        const q = ctx orelse return quickjs.Value.undefined;
        const host = current orelse return quickjs.Value.undefined;
        if (args.len > 0) {
            const value = quickjs.Value.fromCVal(args[0]);
            if (value.toCString(q)) |message| {
                defer q.freeCString(message);
                host.setStatus(std.mem.span(message));
            }
        }
        return quickjs.Value.undefined;
    }

    fn snapshotFn(ctx: ?*quickjs.Context, _: quickjs.Value, _: []const qc.JSValue) quickjs.Value {
        const q = ctx orelse return quickjs.Value.undefined;
        const host = current orelse return quickjs.Value.undefined;
        if (host.snapshot.items.len == 0) return quickjs.Value.undefined;
        return parseJsonIn(q, host.snapshot.items);
    }

    /// seggs.app.action(op) asks for something the shell itself does: showing or
    /// hiding the file list, focusing the prompt, or opening the quick open.
    fn appActionFn(ctx: ?*quickjs.Context, _: quickjs.Value, args: []const qc.JSValue) quickjs.Value {
        const q = ctx orelse return quickjs.Value.undefined;
        const host = current orelse return quickjs.Value.undefined;
        if (args.len < 1) return quickjs.Value.undefined;
        const text = quickjs.Value.fromCVal(args[0]).toCString(q) orelse return quickjs.Value.undefined;
        defer q.freeCString(text);
        const op = std.meta.stringToEnum(ActionOp, std.mem.span(text)) orelse return quickjs.Value.undefined;
        switch (op) {
            .sidebar, .prompt, .quick_open => host.queueAction(op, "") catch |err| {
                std.log.err("app action rejected: {s}", .{@errorName(err)});
            },
            else => {},
        }
        return quickjs.Value.undefined;
    }

    fn agentActionFn(ctx: ?*quickjs.Context, _: quickjs.Value, args: []const qc.JSValue) quickjs.Value {
        return actionFn(ctx, args, false);
    }

    fn editorActionFn(ctx: ?*quickjs.Context, _: quickjs.Value, args: []const qc.JSValue) quickjs.Value {
        return actionFn(ctx, args, true);
    }

    fn actionFn(ctx: ?*quickjs.Context, args: []const qc.JSValue, editor: bool) quickjs.Value {
        const q = ctx orelse return quickjs.Value.undefined;
        const host = current orelse return quickjs.Value.undefined;
        if (args.len < 2) return quickjs.Value.undefined;
        const op_text = quickjs.Value.fromCVal(args[0]).toCString(q) orelse return quickjs.Value.undefined;
        defer q.freeCString(op_text);
        const id_text = quickjs.Value.fromCVal(args[1]).toCString(q) orelse return quickjs.Value.undefined;
        defer q.freeCString(id_text);
        const op_text_slice = std.mem.span(op_text);
        const op: ActionOp = if (editor)
            (if (std.mem.eql(u8, op_text_slice, "open")) .open else .switch_buffer)
        else
            (std.meta.stringToEnum(ActionOp, op_text_slice) orelse return quickjs.Value.undefined);
        host.queueAction(op, std.mem.span(id_text)) catch |err| {
            std.log.err("{s} action rejected: {s}", .{ if (editor) "editor" else "agent", @errorName(err) });
        };
        return quickjs.Value.undefined;
    }

    /// Replace the state extensions read through `seggs.snapshot`. A snapshot is
    /// text because each extension parses it in its own context.
    pub fn setSnapshot(self: *Host, json: []const u8) void {
        self.snapshot.clearRetainingCapacity();
        self.snapshot.appendSlice(self.allocator, json) catch {};
    }

    /// Take the next action an extension asked for. The caller owns the id.
    pub fn nextAction(self: *Host) ?Action {
        if (self.actions.items.len == 0) return null;
        return self.actions.orderedRemove(0);
    }

    fn versionFn(ctx: ?*quickjs.Context, _: quickjs.Value, _: []const qc.JSValue) quickjs.Value {
        const q = ctx orelse return quickjs.Value.undefined;
        return quickjs.Value.initString(q, "0.2.0");
    }

    fn queueAction(self: *Host, op: ActionOp, id: []const u8) !void {
        if (id.len > 512) return error.ActionId;
        switch (op) {
            .sidebar, .prompt, .quick_open => if (id.len != 0) return error.ActionId,
            else => if (id.len == 0) return error.ActionId,
        }
        if (self.actions.items.len >= max_actions) return error.TooManyActions;
        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try self.actions.append(self.allocator, .{ .op = op, .id = owned });
    }

    /// Subscribe one extension to an event. Subscriptions accumulate rather than
    /// replacing, so a second extension does not stop the first one hearing
    /// about events.
    fn registerHandler(self: *Host, extension: *Extension, event: []const u8, callback: quickjs.Value) !void {
        if (event.len == 0 or event.len > 64) return error.EventName;
        if (extension.handlers.items.len >= max_handlers) return error.TooManyHandlers;
        const name = try self.allocator.dupe(u8, event);
        errdefer self.allocator.free(name);
        try extension.handlers.append(self.allocator, .{ .event = name, .callback = callback.dup(extension.ctx) });
    }

    /// Register a panel for one extension. A later registration of the same name
    /// takes over, including from another extension, so the most recent bundle
    /// decides what a region looks like.
    fn registerPanel(self: *Host, extension: *Extension, name: []const u8, provider: quickjs.Value) !void {
        if (name.len == 0 or name.len > 64) return error.PanelName;
        for (self.extensions.items) |other| {
            if (other == extension) continue;
            if (other.panels.fetchOrderedRemove(name)) |entry| {
                self.allocator.free(entry.key);
                entry.value.deinit(other.ctx);
            }
        }
        if (extension.panels.fetchOrderedRemove(name)) |entry| {
            self.allocator.free(entry.key);
            entry.value.deinit(extension.ctx);
        }
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try extension.panels.put(self.allocator, key, provider.dup(extension.ctx));
    }
};
