const std = @import("std");
const c = @import("native");
const Workspace = @import("editor/workspace.zig").Workspace;
const Document = @import("editor/document.zig").Document;
const Scanner = @import("editor/highlight.zig").Scanner;
const Client = @import("acp/client.zig").Client;
const Config = @import("agents/registry.zig").Config;
const Renderer = @import("gpu/renderer.zig").Renderer;
const layout = @import("ui/layout.zig");
const theme = @import("ui/theme.zig");
const text = @import("core/text.zig");
const Rect = layout.Rect;

pub const App = struct {
    const Focus = enum { editor, prompt };
    const Overlay = enum { none, files, commands, quit };
    const commands = [_][]const u8{ "Toggle explorer", "Focus agent prompt", "Start selected agent", "Stop selected agent", "Toggle fullscreen", "Save current file", "Cancel selected turn" };
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    workspace: Workspace,
    clients: []Client,
    active: usize = 0,
    focus: Focus = .editor,
    overlay: Overlay = .none,
    query: std.ArrayList(u8) = .empty,
    query_selected: usize = 0,
    prompt_text: std.ArrayList(u8) = .empty,
    cached: []u8,
    cached_revision: ?u64 = null,
    first_line: usize = 0,
    first_column: usize = 0,
    explorer_first: usize = 0,
    transcript_scroll: usize = 0,
    selection_anchor: ?usize = null,
    drag: bool = false,
    follow_cursor: bool = true,
    sidebar: bool = true,
    fullscreen: bool,
    running: bool = true,
    message: [256]u8 = undefined,
    message_len: usize = 0,
    geometry: layout.Layout = layout.Layout.calculate(1440, 900, true),
    char_width: f32 = 10,
    line_height: f32 = 22,

    pub fn init(a: std.mem.Allocator, window: *c.SDL_Window, config: Config, root: []const u8) !App {
        var workspace = try Workspace.init(a, root);
        errdefer workspace.deinit();
        const clients = try a.alloc(Client, config.agents.len);
        errdefer a.free(clients);
        for (config.agents, clients) |preset, *client| client.* = Client.init(a, preset, root);
        const cached = try workspace.document.snapshot(a);
        var self: App = .{ .allocator = a, .window = window, .workspace = workspace, .clients = clients, .cached = cached, .fullscreen = config.fullscreen };
        self.status("F5 starts the selected agent. Ctrl+P opens files.", .{});
        return self;
    }

    pub fn deinit(self: *App) void {
        for (self.clients) |*client| client.deinit();
        self.allocator.free(self.clients);
        self.workspace.deinit();
        self.allocator.free(self.cached);
        self.query.deinit(self.allocator);
        self.prompt_text.deinit(self.allocator);
    }

    pub fn status(self: *App, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.bufPrint(&self.message, fmt, args) catch {
            const fallback = "Status message too long";
            @memcpy(self.message[0..fallback.len], fallback);
            self.message_len = fallback.len;
            return;
        };
        self.message_len = message.len;
    }

    pub fn openFile(self: *App, path: []const u8) !void {
        try self.workspace.open(path);
        self.cached_revision = null;
        self.first_line = 0;
        self.first_column = 0;
        self.selection_anchor = null;
        self.focus = .editor;
        self.follow_cursor = true;
        self.status("Opened {s}", .{std.fs.path.basename(path)});
    }

    pub fn update(self: *App) !void {
        for (self.clients) |*client| client.pump();
        if (self.cached_revision == null or self.cached_revision.? != self.workspace.document.revision) {
            const bytes = try self.workspace.document.snapshot(self.allocator);
            self.allocator.free(self.cached);
            self.cached = bytes;
            self.cached_revision = self.workspace.document.revision;
        }
    }

    fn requestQuit(self: *App) void {
        if (self.workspace.dirty()) self.overlay = .quit else self.running = false;
    }

    fn selectedRange(self: *const App) ?struct { start: usize, end: usize } {
        const anchor = self.selection_anchor orelse return null;
        const cursor = self.workspace.document.cursor;
        if (anchor == cursor) return null;
        return .{ .start = @min(anchor, cursor), .end = @max(anchor, cursor) };
    }

    fn insert(self: *App, bytes: []const u8) !void {
        if (self.focus == .prompt) {
            if (self.prompt_text.items.len + bytes.len > 16 * 1024) return error.PromptInputLimit;
            try self.prompt_text.appendSlice(self.allocator, bytes);
        } else {
            if (self.selectedRange()) |range| {
                try self.workspace.document.replace(range.start, range.end, bytes);
            } else try self.workspace.document.insert(bytes);
            self.selection_anchor = null;
            self.follow_cursor = true;
        }
    }

    fn submit(self: *App, broadcast: bool) !void {
        if (self.prompt_text.items.len == 0) return;
        var sent: usize = 0;
        if (broadcast) {
            for (self.clients) |*client| {
                if (client.state == .ready) {
                    // Failure in one lane does not suppress delivery to another lane.
                    client.prompt(self.prompt_text.items) catch |err| {
                        self.status("{s}: {s}", .{ client.preset.name, @errorName(err) });
                        continue;
                    };
                    sent += 1;
                }
            }
            if (sent == 0) return error.NoReadyAgents;
        } else {
            try self.clients[self.active].prompt(self.prompt_text.items);
            sent = 1;
        }
        self.prompt_text.clearRetainingCapacity();
        self.transcript_scroll = 0;
        self.status("Prompt sent to {d} agent(s).", .{sent});
    }

    fn startAgent(self: *App) !void {
        try self.clients[self.active].start();
        self.focus = .prompt;
        self.status("Started {s}.", .{self.clients[self.active].preset.name});
    }

    fn toggleFullscreen(self: *App) !void {
        if (!c.SDL_SetWindowFullscreen(self.window, !self.fullscreen)) return error.Fullscreen;
        self.fullscreen = !self.fullscreen;
    }

    pub fn event(self: *App, ev: c.SDL_Event) !void {
        switch (ev.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.requestQuit(),
            c.SDL_EVENT_TEXT_INPUT => {
                const bytes = std.mem.span(ev.text.text);
                if (self.overlay == .files or self.overlay == .commands) {
                    if (self.query.items.len + bytes.len <= 256) try self.query.appendSlice(self.allocator, bytes);
                    self.query_selected = 0;
                } else if (self.overlay == .none) try self.insert(bytes);
            },
            c.SDL_EVENT_KEY_DOWN => try self.key(ev.key),
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (ev.button.button == c.SDL_BUTTON_LEFT) try self.mouseDown(ev.button.x, ev.button.y),
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                self.drag = false;
                if (self.selection_anchor == self.workspace.document.cursor) self.selection_anchor = null;
            },
            c.SDL_EVENT_MOUSE_MOTION => if (self.drag) {
                self.workspace.document.cursor = self.positionAt(ev.motion.x, ev.motion.y);
                self.follow_cursor = true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const delta: i32 = @intFromFloat(-ev.wheel.y * 3);
                const x = ev.wheel.mouse_x;
                const y = ev.wheel.mouse_y;
                if (self.geometry.explorer.contains(x, y)) {
                    self.explorer_first = adjust(self.explorer_first, delta, self.workspace.explorer.entries.items.len);
                } else if (self.geometry.agents.contains(x, y)) {
                    self.transcript_scroll = adjust(self.transcript_scroll, -delta, 50_000);
                } else {
                    const last = countLines(self.cached) - 1;
                    self.first_line = adjust(self.first_line, delta, last);
                    self.follow_cursor = false;
                }
            },
            else => {},
        }
    }

    fn key(self: *App, ev: c.SDL_KeyboardEvent) !void {
        const ctrl = ev.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI) != 0;
        const shift = ev.mod & c.SDL_KMOD_SHIFT != 0;
        const alt = ev.mod & c.SDL_KMOD_ALT != 0;
        const keycode = ev.key;
        if (self.overlay == .quit) {
            if (keycode == c.SDLK_ESCAPE) self.overlay = .none;
            if (keycode == c.SDLK_D) self.running = false;
            if (keycode == c.SDLK_S) {
                try self.workspace.save();
                self.running = false;
            }
            return;
        }
        if (self.overlay != .none) {
            switch (keycode) {
                c.SDLK_ESCAPE => self.overlay = .none,
                c.SDLK_BACKSPACE => {
                    self.query.items.len = text.previous(self.query.items, self.query.items.len);
                    self.query_selected = 0;
                },
                c.SDLK_DOWN => self.query_selected = @min(self.query_selected + 1, self.matchCount() -| 1),
                c.SDLK_UP => self.query_selected -|= 1,
                c.SDLK_RETURN => try self.chooseOverlay(),
                else => {},
            }
            return;
        }
        if (keycode == c.SDLK_F11) return self.toggleFullscreen();
        if (keycode == c.SDLK_F5) return self.startAgent();
        if (keycode == c.SDLK_F6) {
            self.clients[self.active].stop();
            return;
        }
        if (alt and (keycode == c.SDLK_Y or keycode == c.SDLK_N)) {
            try self.clients[self.active].answerPermission(keycode == c.SDLK_Y);
            return;
        }
        if (ctrl) {
            if (keycode >= c.SDLK_1 and keycode <= c.SDLK_8) {
                const index: usize = @intCast(keycode - c.SDLK_1);
                if (index < self.clients.len) {
                    self.active = index;
                    self.focus = .prompt;
                    self.transcript_scroll = 0;
                }
                return;
            }
            switch (keycode) {
                c.SDLK_Q => self.requestQuit(),
                c.SDLK_S => {
                    try self.workspace.save();
                    self.status("Saved. External changes were checked before replacement.", .{});
                },
                c.SDLK_B => self.sidebar = !self.sidebar,
                c.SDLK_L => self.focus = .prompt,
                c.SDLK_P => {
                    self.overlay = if (shift) .commands else .files;
                    self.query.clearRetainingCapacity();
                    self.query_selected = 0;
                },
                c.SDLK_RETURN => try self.submit(shift),
                c.SDLK_X => {
                    if (shift) {
                        try self.clients[self.active].cancel();
                    } else if (self.focus == .editor) {
                        try self.copySelection();
                        if (self.selectedRange()) |range| {
                            try self.workspace.document.replace(range.start, range.end, "");
                            self.selection_anchor = null;
                        }
                    }
                },
                c.SDLK_Z => if (self.focus == .editor) {
                    if (shift) try self.workspace.document.redo() else try self.workspace.document.undo();
                    self.selection_anchor = null;
                    self.follow_cursor = true;
                },
                c.SDLK_Y => if (self.focus == .editor) {
                    try self.workspace.document.redo();
                    self.selection_anchor = null;
                    self.follow_cursor = true;
                },
                c.SDLK_A => if (self.focus == .editor) {
                    self.selection_anchor = 0;
                    self.workspace.document.cursor = self.workspace.document.buffer.len();
                    self.follow_cursor = true;
                },
                c.SDLK_C => try self.copySelection(),
                c.SDLK_V => {
                    const bytes = c.SDL_GetClipboardText();
                    if (bytes != null) {
                        defer c.SDL_free(bytes);
                        try self.insert(std.mem.span(bytes));
                    }
                },
                else => {},
            }
            return;
        }
        if (keycode == c.SDLK_ESCAPE) {
            self.focus = .editor;
            self.selection_anchor = null;
            return;
        }
        if (keycode == c.SDLK_BACKSPACE) {
            if (self.focus == .prompt) {
                self.prompt_text.items.len = text.previous(self.prompt_text.items, self.prompt_text.items.len);
            } else if (self.selectedRange()) |range| {
                try self.workspace.document.replace(range.start, range.end, "");
                self.selection_anchor = null;
            } else try self.workspace.document.backspace();
            self.follow_cursor = true;
            return;
        }
        if (keycode == c.SDLK_RETURN) return self.insert("\n");
        if (keycode == c.SDLK_TAB) return self.insert("    ");
        if (self.focus == .prompt) return;
        const doc = &self.workspace.document;
        const before = doc.cursor;
        const movement = keycode == c.SDLK_LEFT or keycode == c.SDLK_RIGHT or keycode == c.SDLK_UP or keycode == c.SDLK_DOWN or keycode == c.SDLK_HOME or keycode == c.SDLK_END;
        if (movement and shift and self.selection_anchor == null) self.selection_anchor = before;
        if (movement and !shift) self.selection_anchor = null;
        switch (keycode) {
            c.SDLK_LEFT => doc.cursor = doc.previous(doc.cursor),
            c.SDLK_RIGHT => doc.cursor = doc.next(doc.cursor),
            c.SDLK_UP => doc.moveVertical(false),
            c.SDLK_DOWN => doc.moveVertical(true),
            c.SDLK_HOME => doc.cursor = doc.lineStart(doc.cursor),
            c.SDLK_END => doc.cursor = doc.lineEnd(doc.cursor),
            c.SDLK_DELETE => {
                if (self.selectedRange()) |range| {
                    try doc.replace(range.start, range.end, "");
                    self.selection_anchor = null;
                } else try doc.delete();
            },
            else => {},
        }
        if (movement) self.follow_cursor = true;
    }

    fn copySelection(self: *App) !void {
        if (self.focus != .editor) return;
        // Use a fresh snapshot because the cached frame can precede this event.
        const bytes = try self.workspace.document.snapshot(self.allocator);
        defer self.allocator.free(bytes);
        const range = self.selectedRange() orelse return;
        const z = try self.allocator.dupeZ(u8, bytes[range.start..range.end]);
        defer self.allocator.free(z);
        if (!c.SDL_SetClipboardText(z.ptr)) return error.Clipboard;
    }

    fn mouseDown(self: *App, x: f32, y: f32) !void {
        if (self.overlay != .none) return;
        const g = self.geometry;
        if (g.activity.contains(x, y)) {
            if (y < 105) self.sidebar = !self.sidebar else self.focus = .prompt;
        } else if (g.explorer.contains(x, y) and y >= g.explorer.y + 68) {
            const row: usize = @intFromFloat((y - g.explorer.y - 68) / 24);
            const index = self.explorer_first + row;
            if (index < self.workspace.explorer.entries.items.len) try self.openFile(self.workspace.explorer.entries.items[index]);
        } else if (g.agents.contains(x, y)) {
            const lanes_y = g.agents.y + 44;
            const lanes_end = lanes_y + @as(f32, @floatFromInt(self.clients.len)) * 38;
            if (y >= lanes_y and y < lanes_end) {
                self.active = @intFromFloat((y - lanes_y) / 38);
                self.transcript_scroll = 0;
                if (x > g.agents.x + g.agents.w - 76) {
                    if (self.clients[self.active].transport == null) try self.startAgent() else self.clients[self.active].stop();
                }
            } else if (self.clients[self.active].permission != null and self.permissionRect().contains(x, y)) {
                if (y >= self.permissionRect().y + 34) {
                    try self.clients[self.active].answerPermission(x < g.agents.x + g.agents.w / 2);
                }
            }
            self.focus = .prompt;
        } else if (self.editorRect().contains(x, y)) {
            self.focus = .editor;
            self.workspace.document.cursor = self.positionAt(x, y);
            self.selection_anchor = self.workspace.document.cursor;
            self.drag = true;
            self.follow_cursor = false;
        }
    }

    fn editorRect(self: *const App) Rect {
        const r = self.geometry.editor;
        return .{ .x = r.x, .y = r.y + 66, .w = r.w, .h = @max(0, r.h - 66) };
    }

    fn permissionRect(self: *const App) Rect {
        const r = self.geometry.agents;
        return .{ .x = r.x + 10, .y = r.y + r.h - 178, .w = r.w - 20, .h = 66 };
    }

    fn positionAt(self: *App, x: f32, y: f32) usize {
        const r = self.editorRect();
        const line = self.first_line + @as(usize, @intFromFloat(@max(0, (y - r.y - 4) / self.line_height)));
        const column = self.first_column + @as(usize, @intFromFloat(@max(0, (x - r.x - 60) / self.char_width + 0.5)));
        const doc = &self.workspace.document;
        var pos: usize = 0;
        var row: usize = 0;
        while (pos < doc.buffer.len() and row < line) : (pos += 1) {
            if (doc.buffer.byteAt(pos) == '\n') row += 1;
        }
        var col: usize = 0;
        while (pos < doc.buffer.len() and doc.buffer.byteAt(pos) != '\n' and col < column) : (pos = doc.next(pos)) {
            col += if (doc.buffer.byteAt(pos) == '\t') @as(usize, 4) else 1;
        }
        return pos;
    }

    fn match(self: *const App, candidate: []const u8) bool {
        const query = self.query.items;
        if (query.len > candidate.len) return false;
        if (query.len == 0) return true;
        for (0..candidate.len - query.len + 1) |start| if (std.ascii.eqlIgnoreCase(candidate[start .. start + query.len], query)) return true;
        return false;
    }

    fn matchCount(self: *const App) usize {
        var count: usize = 0;
        if (self.overlay == .commands) {
            for (commands) |command| {
                if (self.match(command)) count += 1;
            }
        } else {
            for (self.workspace.explorer.entries.items) |path| {
                if (self.match(path)) count += 1;
            }
        }
        return count;
    }

    fn chooseOverlay(self: *App) !void {
        var index: usize = 0;
        if (self.overlay == .commands) {
            for (commands, 0..) |command, action| {
                if (!self.match(command)) continue;
                if (index == self.query_selected) {
                    self.overlay = .none;
                    switch (action) {
                        0 => self.sidebar = !self.sidebar,
                        1 => self.focus = .prompt,
                        2 => try self.startAgent(),
                        3 => self.clients[self.active].stop(),
                        4 => try self.toggleFullscreen(),
                        5 => try self.workspace.save(),
                        6 => try self.clients[self.active].cancel(),
                        else => unreachable,
                    }
                    return;
                }
                index += 1;
            }
        } else {
            for (self.workspace.explorer.entries.items) |path| {
                if (!self.match(path)) continue;
                if (index == self.query_selected) {
                    try self.openFile(path);
                    self.overlay = .none;
                    return;
                }
                index += 1;
            }
        }
    }

    pub fn draw(self: *App, r: *Renderer, frame: std.mem.Allocator) !void {
        self.char_width = r.atlas.advance;
        self.line_height = r.atlas.line_height;
        self.geometry = layout.Layout.calculate(r.width, r.height, self.sidebar);
        const g = self.geometry;
        try r.rect(.{ .x = 0, .y = 0, .w = r.width, .h = r.height }, theme.background);
        try r.rect(g.title, theme.panel);
        try r.text(16, 11, "SEGGS", theme.accent);
        try r.text(116, 11, "/ agent-native workspace", theme.muted);
        try r.text(@max(400, r.width - 174), 11, "SDL3 GPU / ACP", theme.accent);
        try r.rect(g.activity, theme.panel);
        try r.rect(.{ .x = 0, .y = 54, .w = 3, .h = 36 }, theme.accent);
        try r.text(15, 61, "E", theme.text);
        try r.text(15, 114, "A", theme.muted);
        try r.text(15, 166, ">", theme.muted);
        if (g.explorer.w > 0) try self.drawExplorer(r);
        try self.drawEditor(r);
        try self.drawAgents(r, frame);
        r.clip = .{ .x = 0, .y = 0, .w = r.width, .h = r.height };
        try r.rect(g.status, theme.selected);
        r.clip = g.status;
        try r.text(12, g.status.y + 4, self.message[0..self.message_len], theme.text);
        if (self.overlay != .none) try self.drawOverlay(r);
    }

    fn drawExplorer(self: *App, r: *Renderer) !void {
        const bounds = self.geometry.explorer;
        r.clip = bounds;
        try r.rect(bounds, theme.panel);
        try r.text(bounds.x + 12, bounds.y + 13, "EXPLORER", theme.muted);
        try r.text(bounds.x + 12, bounds.y + 42, std.fs.path.basename(self.workspace.root), theme.accent);
        var y = bounds.y + 68;
        var index = self.explorer_first;
        while (index < self.workspace.explorer.entries.items.len and y < bounds.y + bounds.h - 28) : (index += 1) {
            const path = self.workspace.explorer.entries.items[index];
            const relative = if (path.len > self.workspace.root.len + 1) path[self.workspace.root.len + 1 ..] else path;
            const selected = if (self.workspace.path) |current| std.mem.eql(u8, current, path) else false;
            if (selected) try r.rect(.{ .x = bounds.x + 4, .y = y - 2, .w = bounds.w - 8, .h = 24 }, theme.raised);
            try r.text(bounds.x + 12, y, relative, if (selected) theme.text else theme.muted);
            y += 24;
        }
        try r.text(bounds.x + 12, bounds.y + bounds.h - 24, "Ctrl+P  quick open", theme.muted);
    }

    fn cursorLocation(self: *const App) struct { line: usize, column: usize } {
        var line: usize = 0;
        var col: usize = 0;
        var pos: usize = 0;
        const doc = &self.workspace.document;
        while (pos < doc.cursor) : (pos = doc.next(pos)) {
            const byte = doc.buffer.byteAt(pos);
            if (byte == '\n') {
                line += 1;
                col = 0;
            } else col += if (byte == '\t') @as(usize, 4) else 1;
        }
        return .{ .line = line, .column = col };
    }

    fn drawEditor(self: *App, r: *Renderer) !void {
        const bounds = self.geometry.editor;
        r.clip = bounds;
        try r.rect(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = 36 }, theme.panel);
        var tab_buf: [512]u8 = undefined;
        const name = if (self.workspace.path) |path| std.fs.path.basename(path) else "Welcome.zig";
        const tab = try std.fmt.bufPrint(&tab_buf, "{s}{s}", .{ name, if (self.workspace.dirty()) " *" else "" });
        try r.text(bounds.x + 18, bounds.y + 9, tab, theme.text);
        try r.rect(.{ .x = bounds.x, .y = bounds.y, .w = @min(bounds.w, 210), .h = 2 }, theme.accent);
        const loc = self.cursorLocation();
        var info_buf: [128]u8 = undefined;
        const info = try std.fmt.bufPrint(&info_buf, "UTF-8  /  Ln {d}, Col {d}  /  {d} bytes", .{ loc.line + 1, loc.column + 1, self.cached.len });
        try r.text(bounds.x + 18, bounds.y + 43, info, theme.muted);
        const viewport = self.editorRect();
        r.clip = viewport;
        const rows: usize = @intFromFloat(@max(1, (viewport.h - 8) / self.line_height));
        const cols: usize = @intFromFloat(@max(1, (viewport.w - 80) / self.char_width));
        if (self.follow_cursor) {
            if (loc.line < self.first_line) self.first_line = loc.line;
            if (loc.line >= self.first_line + rows) self.first_line = loc.line - rows + 1;
            if (loc.column < self.first_column) self.first_column = loc.column;
            if (loc.column >= self.first_column + cols) self.first_column = loc.column - cols + 1;
            self.follow_cursor = false;
        }
        const selection = self.selectedRange();
        var lines = std.mem.splitScalar(u8, self.cached, '\n');
        var line_no: usize = 0;
        var offset: usize = 0;
        while (lines.next()) |line| {
            defer {
                line_no += 1;
                offset += line.len + 1;
            }
            if (line_no < self.first_line) continue;
            if (line_no >= self.first_line + rows + 1) break;
            const y = viewport.y + 4 + @as(f32, @floatFromInt(line_no - self.first_line)) * self.line_height;
            if (line_no == loc.line) try r.rect(.{ .x = viewport.x, .y = y, .w = viewport.w, .h = self.line_height }, theme.panel);
            var number_buf: [24]u8 = undefined;
            const number = try std.fmt.bufPrint(&number_buf, "{d}", .{line_no + 1});
            try r.text(viewport.x + 46 - @as(f32, @floatFromInt(number.len)) * self.char_width, y, number, theme.muted);
            r.clip = .{ .x = viewport.x + 56, .y = viewport.y, .w = @max(0, viewport.w - 56), .h = viewport.h };
            var scan: Scanner = .{};
            var pos: usize = 0;
            var column: usize = 0;
            while (pos < line.len) {
                const byte = line[pos];
                const color = scan.color(line, pos);
                const cells: usize = if (byte == '\t') 4 else 1;
                if (column + cells >= self.first_column) {
                    const x = viewport.x + 60 + (@as(f32, @floatFromInt(column)) - @as(f32, @floatFromInt(self.first_column))) * self.char_width;
                    if (x >= viewport.x + viewport.w) break;
                    if (selection) |range| {
                        if (offset + pos >= range.start and offset + pos < range.end) try r.rect(.{ .x = x, .y = y, .w = self.char_width * @as(f32, @floatFromInt(cells)), .h = self.line_height }, theme.selected);
                    }
                    if (byte != '\t' and byte != '\r') try r.glyph(x, y, byte, color);
                }
                pos = text.next(line, pos);
                column += cells;
            }
            r.clip = viewport;
        }
        if (self.focus == .editor and (c.SDL_GetTicks() / 500) % 2 == 0 and loc.line >= self.first_line and loc.line < self.first_line + rows and loc.column >= self.first_column) {
            try r.rect(.{ .x = viewport.x + 60 + @as(f32, @floatFromInt(loc.column - self.first_column)) * self.char_width, .y = viewport.y + 4 + @as(f32, @floatFromInt(loc.line - self.first_line)) * self.line_height, .w = 2, .h = self.line_height }, theme.accent);
        }
    }

    fn stateLabel(state: Client.State) []const u8 {
        return switch (state) {
            .offline => "OFF",
            .initialize => "INIT",
            .new_session => "NEW",
            .ready => "READY",
            .busy => "BUSY",
            .cancelling => "CANCEL",
            .failed => "ERROR",
        };
    }

    fn drawAgents(self: *App, r: *Renderer, frame: std.mem.Allocator) !void {
        const bounds = self.geometry.agents;
        r.clip = bounds;
        try r.rect(bounds, theme.panel);
        try r.rect(.{ .x = bounds.x, .y = bounds.y, .w = 1, .h = bounds.h }, theme.border);
        try r.text(bounds.x + 14, bounds.y + 13, "AGENTS / independent sessions", theme.text);
        for (self.clients, 0..) |client, i| {
            const row: Rect = .{ .x = bounds.x + 8, .y = bounds.y + 44 + @as(f32, @floatFromInt(i)) * 38, .w = bounds.w - 16, .h = 34 };
            try r.rect(row, if (i == self.active) theme.raised else theme.panel);
            const tint = if (client.permission != null) theme.amber else switch (client.state) { .ready => theme.accent, .busy, .cancelling => theme.purple, .failed => theme.red, else => theme.muted };
            try r.rect(.{ .x = row.x + 8, .y = row.y + 13, .w = 7, .h = 7 }, tint);
            var lane_buf: [160]u8 = undefined;
            const lane = try std.fmt.bufPrint(&lane_buf, "{d} {s}", .{ i + 1, client.preset.name });
            r.clip = .{ .x = row.x + 22, .y = row.y, .w = @max(0, row.w - 165), .h = row.h };
            try r.text(row.x + 22, row.y + 8, lane, theme.text);
            r.clip = bounds;
            try r.text(row.x + row.w - 148, row.y + 8, if (client.permission != null) "ASK" else stateLabel(client.state), tint);
            try r.text(row.x + row.w - 59, row.y + 8, if (client.transport == null) "START" else "STOP", theme.accent);
        }
        const transcript_y = bounds.y + 52 + @as(f32, @floatFromInt(self.clients.len)) * 38;
        const transcript_bottom = if (self.clients[self.active].permission != null) self.permissionRect().y - 8 else bounds.y + bounds.h - 110;
        const transcript: Rect = .{ .x = bounds.x + 14, .y = transcript_y, .w = bounds.w - 28, .h = @max(0, transcript_bottom - transcript_y) };
        const client = &self.clients[self.active];
        const bytes = if (client.transcript.items.len == 0) "No agent starts automatically.\n\nF5 starts this agent.\nCtrl+L focuses the prompt.\nCtrl+Enter sends to this agent.\nCtrl+Shift+Enter sends to ready agents.\n\nThe local mock needs no account.\nUse separate worktrees for parallel edits." else client.transcript.items;
        try wrappedTail(r, frame, transcript, bytes, self.transcript_scroll, theme.text);
        r.clip = bounds;
        if (client.permission != null) {
            const permission = self.permissionRect();
            try r.rect(permission, theme.raised);
            try r.rect(.{ .x = permission.x, .y = permission.y, .w = 3, .h = permission.h }, theme.amber);
            r.clip = permission.inset(8);
            try r.text(permission.x + 10, permission.y + 6, client.permissionTitle(), theme.amber);
            try r.text(permission.x + 10, permission.y + 38, "Alt+Y allow once", theme.accent);
            try r.text(permission.x + permission.w / 2, permission.y + 38, "Alt+N reject", theme.red);
        }
        r.clip = bounds;
        const prompt_box: Rect = .{ .x = bounds.x + 10, .y = bounds.y + bounds.h - 102, .w = bounds.w - 20, .h = 66 };
        try r.rect(prompt_box, if (self.focus == .prompt) theme.raised else theme.background);
        if (self.focus == .prompt) try r.rect(.{ .x = prompt_box.x, .y = prompt_box.y, .w = 2, .h = prompt_box.h }, theme.accent);
        try wrappedTail(r, frame, prompt_box.inset(8), if (self.prompt_text.items.len == 0) "Ask this agent..." else self.prompt_text.items, 0, if (self.prompt_text.items.len == 0) theme.muted else theme.text);
        r.clip = bounds;
        try r.text(bounds.x + 14, bounds.y + bounds.h - 27, "Ctrl+Enter send / F5 start / F6 stop", theme.muted);
    }

    fn drawOverlay(self: *App, r: *Renderer) !void {
        r.clip = .{ .x = 0, .y = 0, .w = r.width, .h = r.height };
        try r.rect(r.clip, .{ 0, 0, 0, 0.65 });
        const box: Rect = .{ .x = @max(20, (r.width - 720) / 2), .y = 96, .w = @min(720, r.width - 40), .h = if (self.overlay == .quit) 176 else 368 };
        try r.rect(box, theme.raised);
        r.clip = box.inset(14);
        if (self.overlay == .quit) {
            try r.text(box.x + 20, box.y + 20, "Unsaved changes", theme.amber);
            try r.text(box.x + 20, box.y + 62, "S  Save and quit", theme.text);
            try r.text(box.x + 20, box.y + 90, "D  Discard and quit", theme.red);
            try r.text(box.x + 20, box.y + 118, "Esc  Return to the editor", theme.muted);
            return;
        }
        try r.text(box.x + 20, box.y + 16, if (self.overlay == .commands) "COMMANDS" else "QUICK OPEN", theme.accent);
        try r.text(box.x + 20, box.y + 46, if (self.query.items.len == 0) "Type to filter..." else self.query.items, theme.text);
        const start = self.query_selected -| 8;
        var index: usize = 0;
        if (self.overlay == .commands) {
            for (commands) |command| {
                if (!self.match(command)) continue;
                try self.overlayRow(r, box, command, index, start);
                index += 1;
            }
        } else {
            for (self.workspace.explorer.entries.items) |path| {
                if (!self.match(path)) continue;
                const relative = if (path.len > self.workspace.root.len + 1) path[self.workspace.root.len + 1 ..] else path;
                try self.overlayRow(r, box, relative, index, start);
                index += 1;
            }
        }
    }

    fn overlayRow(self: *App, r: *Renderer, box: Rect, label: []const u8, index: usize, start: usize) !void {
        if (index < start or index > start + 8) return;
        const y = box.y + 88 + @as(f32, @floatFromInt(index - start)) * 28;
        if (index == self.query_selected) try r.rect(.{ .x = box.x + 12, .y = y - 3, .w = box.w - 24, .h = 28 }, theme.selected);
        try r.text(box.x + 20, y, label, theme.text);
    }
};

fn adjust(value: usize, delta: i32, maximum: usize) usize {
    if (delta < 0) return value -| @as(usize, @intCast(-delta));
    return @min(maximum, value +| @as(usize, @intCast(delta)));
}

fn countLines(bytes: []const u8) usize {
    var n: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') n += 1;
    }
    return n;
}

fn wrappedTail(r: *Renderer, frame: std.mem.Allocator, rect: Rect, bytes: []const u8, scroll: usize, color: theme.Color) !void {
    if (rect.h < r.atlas.line_height or rect.w <= 0) return;
    r.clip = rect;
    const columns: usize = @intFromFloat(@max(1, rect.w / r.atlas.advance));
    const rows: usize = @intFromFloat(rect.h / r.atlas.line_height);
    var spans: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var pos: usize = 0;
    var column: usize = 0;
    while (pos < bytes.len) {
        if (bytes[pos] == '\n' or column >= columns) {
            try spans.append(frame, bytes[start..pos]);
            if (bytes[pos] == '\n') pos += 1;
            start = pos;
            column = 0;
            continue;
        }
        pos = text.next(bytes, pos);
        column += 1;
    }
    try spans.append(frame, bytes[start..]);
    const end = spans.items.len -| @min(scroll, spans.items.len -| 1);
    const begin = end -| rows;
    for (spans.items[begin..end], 0..) |span, row| try r.text(rect.x, rect.y + @as(f32, @floatFromInt(row)) * r.atlas.line_height, span, color);
}
