const std = @import("std");
const builtin = @import("builtin");
const c = @import("native");
const Workspace = @import("editor/workspace.zig").Workspace;
const Document = @import("editor/document.zig").Document;
const highlight = @import("editor/highlight.zig");
const prompt = @import("editor/prompt.zig");
const Client = @import("acp/client.zig").Client;
const lsp = @import("services/lsp.zig");
const Config = @import("agents/registry.zig").Config;
const Renderer = @import("gpu/renderer.zig").Renderer;
const layout = @import("ui/layout.zig");
const vt = @import("services/vt.zig");
const pty = @import("services/pty.zig");
const process = @import("services/process.zig");
const ghostty = @import("ghostty");
const theme = @import("ui/theme.zig");
const runs = @import("editor/runs.zig");

/// The dividers between docks, which is what a reader drags to resize one.
const Divider = enum { explorer, agents, terminal };

/// A context row in the inspector is its name and, under it, what it would
/// carry. The height follows the line metrics rather than a number chosen for
/// one font size, because the interface does not get to decide how tall a line
/// of text is.
fn inspectorRowHeight(line_height: f32) f32 {
    return line_height * 2 + 8;
}
const review = @import("editor/review.zig");
const wrap = @import("ui/wrap.zig");
const shell_integration = @import("services/shell.zig");
const terminals = @import("services/terminals.zig");
const tree_widget = @import("ui/tree.zig");

/// Shown in place of a panel when no extension registered one, so a session
/// without extensions still explains itself.
const default_help = "No agent starts automatically.\n\nF5 starts this agent.\nCtrl+L focuses the prompt.\nCtrl+Enter sends to this agent.\nCtrl+Shift+Enter sends to ready agents.";

/// A panel and the box it occupied, recorded while drawing.
const PanelRect = struct { name: []const u8, bounds: Rect };

/// A named node an extension described, and the panel it belongs to. One list
/// per frame answers clicks, hover, and focus order, so none of them need a
/// second walk of the tree.
const PanelNode = struct { panel: []const u8, id: []const u8, bounds: Rect, focusable: bool };
const text = @import("core/text.zig");
const Preedit = @import("core/preedit.zig").Preedit;
const Host = @import("ext/host.zig").Host;
const ext_ui = @import("ext/ui.zig");
const Rect = layout.Rect;

pub const App = struct {
    const Focus = enum { editor, prompt, panels, terminal };

    /// What the centre of the window is about. A perspective is a view of the
    /// same workspace and run, not a separate application: switching keeps the
    /// open file and the selected run.
    const Perspective = enum { code, review, compose };

    /// What the left dock navigates. The roadmap's rail is the long version of
    /// this; two things to look at is where it starts.
    const Dock = enum { files, runs };
    const Overlay = enum { none, files, commands, quit };
    const commands = [_][]const u8{ "Toggle explorer", "Focus agent prompt", "Start selected agent", "Stop selected agent", "Toggle fullscreen", "Save current file", "Cancel selected turn", "New run: plan, implement, review", "Review changes", "Show runs", "Compose the run" };
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
    preedit: Preedit = .{},
    /// Extension host, when one is attached. Panels come from it.
    host: ?*Host = null,
    /// Interface an extension described, rebuilt each frame it is drawn.
    panel_tree: ext_ui.Tree,
    /// Where each registered panel was drawn, so a click can be routed back to
    /// it. The names borrow the host's keys, which outlive the frame.
    panel_rects: std.ArrayListUnmanaged(PanelRect) = .empty,
    /// Named nodes of the panels drawn this frame, in document order. The ids are
    /// owned here because the tree they came from is parsed per panel and freed
    /// as soon as the next one is read.
    panel_nodes: std.ArrayListUnmanaged(PanelNode) = .empty,
    /// Which of those take part in Tab order, as indices into `panel_nodes`.
    focus_order: std.ArrayListUnmanaged(usize) = .empty,
    /// What the inspector will carry with the next prompt: a selection, the
    /// file it came from, and what the terminal last printed. Nothing travels
    /// that the developer did not switch on.
    inspector_context: [3]bool = .{ true, false, false },

    /// What the review surface is about: changes proposed by an extension, by
    /// a language server, or by the person, none of which are applied until
    /// somebody accepts them.
    review: review.ReviewQueue,

    /// Which surface the centre shows, and which change is selected in it.
    perspective: Perspective = .code,
    review_selected: usize = 0,
    compose_selected: usize = 0,

    /// Scratch for the inspector's own labels, so drawing does not allocate.
    inspector_scratch: [3][64]u8 = undefined,

    /// Runs this session knows about, oldest first. A run is the work rather
    /// than a panel: it keeps its identity, its steps, and its artifacts
    /// whether or not anything is looking at it, and starting another one does
    /// not throw the first away.
    runs: std.ArrayList(runs.Run) = .empty,

    /// Which run the inspector and the navigator are about.
    run_index: usize = 0,

    /// Which way the left dock is looking.
    dock: Dock = .files,

    /// The source navigator: the workspace's files as the folders that hold
    /// them. A flat list of paths is what enumeration gives; a tree is what a
    /// reader navigates.
    files: tree_widget.Tree,
    /// First row the tree is showing, for scrolling.
    tree_first: usize = 0,

    /// Position in `focus_order` while the panels own the keyboard.
    panel_focus: usize = 0,
    /// Node the pointer is over, owned for the same reason the ids are.
    hover_id: std.ArrayListUnmanaged(u8) = .empty,
    /// Frames drawn since startup. The caret blinks on it rather than on the
    /// clock, so the same frame of two runs renders the same pixels and a
    /// screenshot comparison is meaningful.
    frame_count: u64 = 0,
    /// Last status an extension wrote, so the same message is applied once. It
    /// must not be compared against the current message, or an extension's stale
    /// one would keep overwriting what the editor says afterwards.
    host_status: [256]u8 = undefined,
    host_status_len: usize = 0,
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
    geometry: layout.Layout = layout.Layout.calculateDefault(1440, 900, true),
    /// The shell dock: a program's bytes, interpreted by libghostty-vt into a
    /// screen the renderer draws. The shell outlives a closed dock, which is
    /// what a terminal in an editor is for.
    terminal: ?vt.Terminal = null,
    shell: ?pty.Pty = null,
    /// What the reader has dragged a dock to, if anything.
    resize: layout.Layout.Resize = .{},
    dragging_divider: ?Divider = null,

    /// What the pointer has dragged over in the terminal, when it has.
    terminal_selection: ?TerminalSelection = null,
    terminal_dragging: bool = false,

    /// The terminal dock's sessions. A tab is one shell with its own screen.
    shells: terminals.Terminals,
    terminal_read: std.ArrayList(u8) = .empty,
    terminal_encode: [256]u8 = undefined,
    /// The fraction of the body the terminal dock takes when it is open.
    terminal_fraction: f32 = 0.28,
    /// Whether the dock is on screen. The sessions keep running while it is
    /// away: this is the dock, not the shells.
    terminal_shown: bool = true,
    char_width: f32 = 10,
    line_height: f32 = 22,
    last_watch: u64 = 0,
    lsp_command: []const []const u8,
    lsp_client: ?lsp.Client = null,

    pub fn init(a: std.mem.Allocator, window: *c.SDL_Window, config: Config, root: []const u8) !App {
        var workspace = try Workspace.init(a, root);
        errdefer workspace.deinit();
        const clients = try a.alloc(Client, config.agents.len);
        errdefer a.free(clients);
        for (config.agents, clients) |preset, *client| client.* = Client.init(a, preset, root);
        const cached = try workspace.activeDocument().snapshot(a);
        var self: App = .{ .allocator = a, .window = window, .workspace = workspace, .clients = clients, .cached = cached, .fullscreen = config.fullscreen, .lsp_command = config.lsp, .panel_tree = ext_ui.Tree.init(a), .review = review.ReviewQueue.init(a), .files = tree_widget.Tree.init(a), .shells = terminals.Terminals.init(a) };
        try self.rebuildFiles();
        self.status("F5 starts the selected agent. Ctrl+P opens files.", .{});
        return self;
    }

    pub fn deinit(self: *App) void {
        // The shell is killed and reaped before the emulator that read it
        // goes away, and the buffer between them with them.
        self.shells.deinit();
        self.terminal_read.deinit(self.allocator);
        if (self.lsp_client) |*client| client.deinit();
        for (self.clients) |*client| client.deinit();
        self.allocator.free(self.clients);
        self.workspace.deinit();
        self.allocator.free(self.cached);
        self.query.deinit(self.allocator);
        self.prompt_text.deinit(self.allocator);
        self.preedit.deinit(self.allocator);
        for (self.runs.items) |*run| run.deinit();
        self.runs.deinit(self.allocator);
        self.review.deinit();
        self.files.deinit();
        self.panel_tree.deinit();
        self.panel_rects.deinit(self.allocator);
        for (self.panel_nodes.items) |node| self.allocator.free(node.id);
        self.panel_nodes.deinit(self.allocator);
        self.focus_order.deinit(self.allocator);
        self.hover_id.deinit(self.allocator);
    }

    /// The status bar's current message, for callers outside the interface.
    pub fn statusText(self: *const App) []const u8 {
        return self.message[0..self.message_len];
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
        self.refreshLsp(path) catch |err| {
            std.log.err("lsp: {s}", .{@errorName(err)});
            self.status("language server: {s}", .{@errorName(err)});
        };
    }

    /// Restart the language server for `path` and publish its diagnostics.
    /// A missing or slow server is reported in the status bar, not fatal.
    fn refreshLsp(self: *App, path: []const u8) !void {
        if (self.lsp_client) |*client| client.deinit();
        self.lsp_client = null;
        if (self.lsp_command.len == 0) return;
        const bytes = try self.workspace.activeDocument().snapshot(self.allocator);
        defer self.allocator.free(bytes);
        var client = try lsp.Client.start(self.allocator, self.lsp_command, self.workspace.root);
        client.timeout_ms = 2_000;
        errdefer client.deinit();
        try client.open(path, bytes);
        self.lsp_client = client;
        std.log.info("lsp: {d} diagnostic(s) in {s}", .{ client.diagnostics.items.len, std.fs.path.basename(path) });
        if (client.diagnostics.items.len > 0) {
            self.status("{d} diagnostic(s): {s}", .{ client.diagnostics.items.len, client.diagnostics.items[0].message });
        }
    }

    /// Byte offset for a zero-based line and column, or null when out of range.
    fn offsetAt(self: *App, line: u32, character: u32) ?usize {
        const doc = self.workspace.activeDocument();
        if (line >= doc.lineCount()) return null;
        var pos = doc.lineStartAt(line);
        var column: u32 = 0;
        while (column < character and pos < self.cached.len) : (pos = doc.next(pos)) {
            const byte = self.cached[pos];
            if (byte == '\n') break;
            column += if (byte == '\t') 4 else 1;
        }
        return pos;
    }

    fn hasDiagnostic(self: *App, line: usize) bool {
        const client = if (self.lsp_client) |*client_ptr| client_ptr else return false;
        for (client.diagnostics.items) |diagnostic| {
            if (diagnostic.line == line) return true;
        }
        return false;
    }

    /// F12 jumps to the definition. Shift+F12 reports references instead.
    fn navigate(self: *App, references: bool) !void {
        const client = if (self.lsp_client) |*client_ptr| client_ptr else {
            self.status("No language server configured.", .{});
            return;
        };
        const path = self.workspace.activePath() orelse return;
        const loc = self.cursorLocation();
        if (references) {
            const list = try client.references(path, @intCast(loc.line), @intCast(loc.column));
            defer lsp.freeLocations(self.allocator, list);
            if (list.len == 0) {
                self.status("No references.", .{});
                return;
            }
            self.status("{d} reference(s); first on line {d}", .{ list.len, list[0].line + 1 });
            return;
        }
        const target = (try client.definition(path, @intCast(loc.line), @intCast(loc.column))) orelse {
            self.status("No definition.", .{});
            return;
        };
        defer target.deinit(self.allocator);
        if (!std.mem.eql(u8, target.path, path)) {
            self.status("Definition is in {s}", .{std.fs.path.basename(target.path)});
            return;
        }
        if (self.offsetAt(target.line, target.character)) |offset| {
            self.workspace.activeDocument().cursor = offset;
            self.selection_anchor = null;
            self.follow_cursor = true;
        }
        self.status("Definition on line {d}", .{target.line + 1});
    }

    fn showHover(self: *App) !void {
        const client = if (self.lsp_client) |*client_ptr| client_ptr else {
            self.status("No language server configured.", .{});
            return;
        };
        const path = self.workspace.activePath() orelse return;
        const loc = self.cursorLocation();
        const hover_text = (try client.hover(path, @intCast(loc.line), @intCast(loc.column))) orelse {
            self.status("No hover information.", .{});
            return;
        };
        defer self.allocator.free(hover_text);
        self.status("{s}", .{hover_text});
    }

    pub fn update(self: *App) !void {
        self.drainActions();
        self.pumpTerminal();
        for (self.clients) |*client| client.pump();
        self.advanceRun();
        const now = c.SDL_GetTicks();
        if (now -| self.last_watch > 1000) {
            self.last_watch = now;
            if (self.workspace.externalChanged(self.workspace.activeIndex())) {
                self.status("File changed on disk. Ctrl+R reloads.", .{});
            }
        }
        if (self.cached_revision == null or self.cached_revision.? != self.workspace.activeDocument().revision) {
            const bytes = try self.workspace.activeDocument().snapshot(self.allocator);
            self.allocator.free(self.cached);
            self.cached = bytes;
            self.cached_revision = self.workspace.activeDocument().revision;
        }
    }

    fn requestQuit(self: *App) void {
        if (self.workspace.dirty()) self.overlay = .quit else self.running = false;
    }

    fn selectedRange(self: *App) ?struct { start: usize, end: usize } {
        const anchor = self.selection_anchor orelse return null;
        const cursor = self.workspace.activeDocument().cursor;
        if (anchor == cursor) return null;
        return .{ .start = @min(anchor, cursor), .end = @max(anchor, cursor) };
    }

    fn insert(self: *App, bytes: []const u8) !void {
        if (self.focus == .prompt) {
            if (self.prompt_text.items.len + bytes.len > 16 * 1024) return error.PromptInputLimit;
            try self.prompt_text.appendSlice(self.allocator, bytes);
        } else {
            if (self.selectedRange()) |range| {
                try self.workspace.activeDocument().replace(range.start, range.end, bytes);
            } else try self.workspace.activeDocument().insert(bytes);
            self.selection_anchor = null;
            self.follow_cursor = true;
        }
    }

    fn submit(self: *App, broadcast: bool) !void {
        // A request does not need words when it carries context. Selecting code
        // and sending it is a complete ask - the code is what is being asked
        // about - and requiring a sentence as well is how a selection ends up
        // being impossible to send.
        if (self.prompt_text.items.len == 0 and !self.carriesContext()) return;
        const message = try self.promptWithContext();
        defer self.allocator.free(message);
        var sent: usize = 0;
        if (broadcast) {
            for (self.clients) |*client| {
                if (client.state == .ready) {
                    // Failure in one lane does not suppress delivery to another lane.
                    client.prompt(message) catch |err| {
                        self.status("{s}: {s}", .{ client.preset.name, @errorName(err) });
                        continue;
                    };
                    sent += 1;
                }
            }
            if (sent == 0) return error.NoReadyAgents;
        } else {
            try self.clients[self.active].prompt(message);
            sent = 1;
        }
        self.prompt_text.clearRetainingCapacity();
        self.transcript_scroll = 0;
        self.status("Prompt sent to {d} agent(s).", .{sent});
    }

    /// Whether the inspector has anything switched on that a request could
    /// carry. Someone who switched it on meant to send it.
    pub fn carriesContext(self: *App) bool {
        if (self.inspector_context[0] and self.selectedRange() != null) return true;
        if (self.inspector_context[1]) return true;
        if (self.inspector_context[2] and self.activeTerminal() != null) return true;
        return false;
    }

    /// Build the outgoing prompt: the current selection plus the language
    /// server's diagnostics for the active file.
    fn promptWithContext(self: *App) ![]u8 {
        const document = self.workspace.activeDocument();
        var label: [48]u8 = undefined;
        var range_label: ?[]const u8 = null;
        var selection: ?[]u8 = null;
        if (self.inspector_context[0]) {
            if (self.selectedRange()) |span| {
                const bytes = try document.snapshot(self.allocator);
                defer self.allocator.free(bytes);
                selection = try self.allocator.dupe(u8, bytes[span.start..span.end]);
                range_label = std.fmt.bufPrint(&label, "{d}-{d}", .{
                    document.lineOf(span.start) + 1, document.lineOf(span.end) + 1,
                }) catch null;
            }
        }
        defer if (selection) |sel| self.allocator.free(sel);

        // A whole buffer is a large attachment, so it travels only when it was
        // switched on, and the inspector says how large.
        var file: ?[]u8 = null;
        if (self.inspector_context[1]) file = try document.snapshot(self.allocator);
        defer if (file) |body| self.allocator.free(body);

        // The terminal's last command is a result with a command line, when the
        // shell reported one. A screen with no markers attached as a command
        // would be a claim about what ran that nothing supports, so it is
        // attached as what it is: the screen.
        var command: ?[]u8 = null;
        var output: ?[]u8 = null;
        if (self.inspector_context[2]) {
            if (self.activeTerminal()) |terminal| {
                if (terminal.lastCommand(self.allocator) catch null) |result| {
                    var owned = result;
                    command = owned.command;
                    output = owned.output;
                    owned.command = &.{};
                    owned.output = &.{};
                } else {
                    output = self.terminalScreen(self.allocator) catch null;
                }
            }
        }
        defer if (command) |body| self.allocator.free(body);
        defer if (output) |body| self.allocator.free(body);

        const diagnostics = try self.diagnosticContext();
        defer self.allocator.free(diagnostics);
        return prompt.attach(self.allocator, .{
            .path = self.workspace.activePath(),
            .range = range_label,
            .selection = selection,
            .file = file,
            .diagnostics = diagnostics,
            .command = command,
            .output = output,
        }, self.prompt_text.items);
    }

    /// Diagnostics for the active file, shaped for the prompt attachment.
    fn diagnosticContext(self: *App) ![]prompt.Diagnostic {
        const sources: []const lsp.Diagnostic = if (self.lsp_client) |*client_ptr| client_ptr.diagnostics.items else &.{};
        const list = try self.allocator.alloc(prompt.Diagnostic, sources.len);
        for (sources, list) |source, *target| target.* = .{ .line = source.line, .message = source.message };
        return list;
    }

    pub fn startAgent(self: *App) !void {
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
            c.SDL_EVENT_TEXT_EDITING => {
                // In-progress IME composition. The committed text arrives later
                // as a text-input event, so this only tracks the preview.
                if (self.overlay != .none or self.focus != .editor) {
                    self.preedit.clear();
                } else {
                    try self.preedit.update(self.allocator, std.mem.span(ev.edit.text), ev.edit.start, ev.edit.length);
                }
            },
            c.SDL_EVENT_TEXT_INPUT => {
                self.preedit.clear();
                const bytes = std.mem.span(ev.text.text);
                if (self.overlay == .files or self.overlay == .commands) {
                    if (self.query.items.len + bytes.len <= 256) try self.query.appendSlice(self.allocator, bytes);
                    self.query_selected = 0;
                } else if (self.perspective == .review) {
                    // The review surface takes keys, not text.
                } else if (self.focus == .terminal) {
                    try self.terminalText(bytes);
                } else if (self.overlay == .none) try self.insert(bytes);
            },
            c.SDL_EVENT_KEY_DOWN => try self.key(ev.key),
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (ev.button.button == c.SDL_BUTTON_LEFT) try self.mouseDown(ev.button.x, ev.button.y),
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                self.drag = false;
                self.terminal_dragging = false;
                self.dragging_divider = null;
                if (self.selection_anchor == self.workspace.activeDocument().cursor) self.selection_anchor = null;
            },
            c.SDL_EVENT_MOUSE_MOTION => if (self.dragging_divider) |divider| {
                self.dragDivider(divider, ev.motion.x, ev.motion.y);
            } else if (self.terminal_dragging) {
                if (self.terminal_selection) |*selection| selection.cursor = self.terminalCell(ev.motion.x, ev.motion.y);
            } else if (!self.drag) self.hoverPanel(ev.motion.x, ev.motion.y) else {
                self.workspace.activeDocument().cursor = self.positionAt(ev.motion.x, ev.motion.y);
                self.follow_cursor = true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const delta: i32 = @intFromFloat(-ev.wheel.y * 3);
                const x = ev.wheel.mouse_x;
                const y = ev.wheel.mouse_y;
                if (self.terminalOpen() and self.geometry.terminal.contains(x, y)) {
                    self.scrollTerminal(delta, x, y);
                } else if (self.geometry.explorer.contains(x, y)) {
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
        if (keycode == c.SDLK_F12) return self.navigate(shift);
        if (keycode == c.SDLK_F5) return self.startAgent();
        if (keycode == c.SDLK_F6) {
            self.clients[self.active].stop();
            return;
        }
        if (alt and (keycode == c.SDLK_Y or keycode == c.SDLK_N)) {
            try self.clients[self.active].answerPermission(keycode == c.SDLK_Y);
            return;
        }
        // The review perspective owns the plain keys while it is open: it
        // is what is on screen, and nothing is being typed into the editor.
        if (self.perspective == .review and !ctrl and !alt) {
            switch (keycode) {
                c.SDLK_UP => self.review_selected -|= 1,
                c.SDLK_DOWN => self.selectNextReview(),
                c.SDLK_A => try self.acceptReview(),
                c.SDLK_R => self.rejectReview(),
                c.SDLK_ESCAPE => self.perspective = .code,
                else => {},
            }
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
                c.SDLK_GRAVE => try self.toggleTerminal(),
                c.SDLK_Q => self.requestQuit(),
                c.SDLK_S => {
                    try self.workspace.save();
                    self.status("Saved. External changes were checked before replacement.", .{});
                },
                c.SDLK_B => self.sidebar = !self.sidebar,
                c.SDLK_I => try self.showHover(),
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
                            try self.workspace.activeDocument().replace(range.start, range.end, "");
                            self.selection_anchor = null;
                        }
                    }
                },
                c.SDLK_Z => if (self.focus == .editor) {
                    if (shift) try self.workspace.activeDocument().redo() else try self.workspace.activeDocument().undo();
                    self.selection_anchor = null;
                    self.follow_cursor = true;
                },
                c.SDLK_Y => if (self.focus == .editor) {
                    try self.workspace.activeDocument().redo();
                    self.selection_anchor = null;
                    self.follow_cursor = true;
                },
                c.SDLK_W => {
                    if (shift) {
                        self.perspective = if (self.perspective == .compose) .code else .compose;
                    } else {
                        // The tab a reader is looking at is the one they mean to
                        // close, and closing the last one puts the dock away.
                        self.closeTerminalTab();
                    }
                },
                c.SDLK_T => if (shift) try self.newTerminalTab(),
                c.SDLK_LEFT => if (shift) self.moveTerminalTab(false),
                c.SDLK_RIGHT => if (shift) self.moveTerminalTab(true),
                c.SDLK_A => {
                    // A run waiting for a person takes precedence over the
                    // editor's own shortcut: it is the only thing here that
                    // another outcome depends on.
                    if (shift and self.runWaiting()) {
                        try self.approveStep();
                    } else if (self.focus == .editor) {
                        self.selection_anchor = 0;
                        self.workspace.activeDocument().cursor = self.workspace.activeDocument().buffer.len();
                        self.follow_cursor = true;
                    }
                },
                c.SDLK_TAB => self.switchBuffer(!shift),
                c.SDLK_R => {
                    if (self.workspace.reload()) |_| {
                        self.cached_revision = null;
                        self.first_line = 0;
                        self.first_column = 0;
                        self.selection_anchor = null;
                        // Files move on disk while the editor is open, so the
                        // navigator is rebuilt with them rather than left
                        // showing a tree that is no longer there.
                        self.rebuildFiles() catch {};
                        self.status("Reloaded from disk.", .{});
                    } else |err| {
                        self.status("Reload failed: {s}", .{@errorName(err)});
                    }
                },
                c.SDLK_C => {
                    // A terminal's Ctrl+C belongs to the program running in it,
                    // so copying from the terminal takes the shift - and the
                    // editor keeps the plain key.
                    if (shift and self.focus == .terminal) {
                        try self.copyTerminalSelection();
                    } else {
                        try self.copySelection();
                    }
                },
                c.SDLK_V => {
                    const bytes = c.SDL_GetClipboardText();
                    if (bytes != null) {
                        defer c.SDL_free(bytes);
                        // A focused terminal takes the paste through the
                        // emulator, which wraps it when the program asked for
                        // bracketed paste and strips what would be a command.
                        if (self.focus == .terminal) {
                            try self.terminalPaste(std.mem.span(bytes));
                        } else {
                            try self.insert(std.mem.span(bytes));
                        }
                    }
                },
                else => {},
            }
            return;
        }
        if (self.focus == .panels) {
            self.panelKey(keycode, shift);
            return;
        }
        if (self.focus == .terminal) {
            // A focused terminal owns the keyboard: the shell is the program
            // that wants Ctrl+C and every other control key.
            if (ctrl and keycode == c.SDLK_GRAVE) return self.toggleTerminal();
            try self.terminalKey(keycode, ctrl, shift, alt);
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
                try self.workspace.activeDocument().replace(range.start, range.end, "");
                self.selection_anchor = null;
            } else try self.workspace.activeDocument().backspace();
            self.follow_cursor = true;
            return;
        }
        if (keycode == c.SDLK_RETURN) return self.insert("\n");
        if (keycode == c.SDLK_TAB) return self.insert("    ");
        if (self.focus == .prompt) return;
        const doc = self.workspace.activeDocument();
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

    /// Publish the state extensions read through `seggs.snapshot`. It is built
    /// on the frame arena, so nothing accumulates: the host parses it as soon as
    /// it is set and never holds the text.
    fn publishSnapshot(self: *App, frame: std.mem.Allocator) !void {
        const host = self.host orelse return;
        const Lane = struct { id: []const u8, name: []const u8, state: []const u8, running: bool };
        const Files = struct {
            root: []const u8,
            entries: []const []const u8,
            selected: []const u8,
            scroll: usize,
        };
        const Buffers = struct { names: []const []const u8, active: usize };
        const lanes = try frame.alloc(Lane, self.clients.len);
        for (self.clients, lanes) |*client, *lane| {
            lane.* = .{
                .id = client.preset.id,
                .name = client.preset.name,
                .state = @tagName(client.state),
                .running = client.transport != null,
            };
        }
        const doc = self.workspace.activeDocument();
        const location = self.cursorLocation();
        const entries = try frame.alloc([]const u8, self.workspace.explorer.entries.items.len);
        for (self.workspace.explorer.entries.items, entries) |path, *relative| relative.* = self.relativePath(path);
        const names = try frame.alloc([]const u8, self.workspace.buffers.items.len);
        for (0..names.len) |index| names[index] = self.workspace.bufferName(index);
        const json = try std.json.Stringify.valueAlloc(frame, .{
            .agents = lanes,
            .active = self.active,
            .status = self.message[0..self.message_len],
            .sidebar = self.sidebar,
            .focus = @tagName(self.focus),
            .files = Files{
                .root = std.fs.path.basename(self.workspace.root),
                .entries = entries,
                .selected = self.relativePath(self.workspace.activePath() orelse ""),
                .scroll = self.explorer_first,
            },
            .buffers = Buffers{ .names = names, .active = self.workspace.activeIndex() },
            .editor = .{
                .file = self.workspace.activePath() orelse "",
                .line = location.line + 1,
                .column = location.column + 1,
                .bytes = doc.buffer.len(),
                .dirty = self.workspace.dirty(),
            },
        }, .{});
        host.setSnapshot(json);
    }

    /// Apply what extensions asked for. Requests are queued by a handler and
    /// applied here, between frames, so a handler never mutates the interface
    /// while a frame is being drawn.
    fn drainActions(self: *App) void {
        const host = self.host orelse return;
        while (host.nextAction()) |action| {
            defer self.allocator.free(action.id);
            switch (action.op) {
                // Editor actions name a path or a buffer, not a client.
                .open => {
                    // The panel reports the path as it shows it, relative to the
                    // workspace root.
                    for (self.workspace.explorer.entries.items) |path| {
                        if (!std.mem.eql(u8, self.relativePath(path), action.id)) continue;
                        self.openFile(path) catch |err| self.status("Open failed: {s}", .{@errorName(err)});
                        break;
                    }
                },
                .switch_buffer => {
                    for (0..self.workspace.buffers.items.len) |target| {
                        if (!std.mem.eql(u8, self.workspace.bufferName(target), action.id)) continue;
                        self.workspace.switchTo(target);
                        self.cached_revision = null;
                        self.first_line = 0;
                        self.first_column = 0;
                        self.selection_anchor = null;
                        break;
                    }
                },
                // Actions the shell itself carries out.
                .sidebar, .prompt, .quick_open => {
                    std.log.info("app action: {s}", .{@tagName(action.op)});
                    switch (action.op) {
                        .sidebar => self.sidebar = !self.sidebar,
                        .prompt => self.focus = .prompt,
                        else => {
                            self.overlay = .files;
                            self.query.clearRetainingCapacity();
                            self.query_selected = 0;
                        },
                    }
                },
                .activate, .start, .stop => {
                    const index = self.clientIndex(action.id) orelse continue;
                    std.log.info("agent action: {s} {s}", .{ @tagName(action.op), action.id });
                    switch (action.op) {
                        .activate => {
                            self.active = index;
                            self.transcript_scroll = 0;
                        },
                        .start => {
                            self.active = index;
                            self.startAgent() catch |err| self.status("Start failed: {s}", .{@errorName(err)});
                        },
                        .stop => self.clients[index].stop(),
                        else => unreachable,
                    }
                },
            }
        }
    }

    /// Path as the explorer shows it: relative to the workspace root.
    fn relativePath(self: *const App, path: []const u8) []const u8 {
        return if (path.len > self.workspace.root.len + 1) path[self.workspace.root.len + 1 ..] else path;
    }

    fn clientIndex(self: *const App, id: []const u8) ?usize {
        for (self.clients, 0..) |*client, index| {
            if (std.mem.eql(u8, client.preset.id, id)) return index;
        }
        return null;
    }

    /// Show what an extension last wrote through `seggs.status`. Without this an
    /// extension could only be heard while it was loading.
    fn syncHostStatus(self: *App) void {
        const host = self.host orelse return;
        const message = host.status();
        if (message.len == 0) return;
        if (std.mem.eql(u8, message, self.host_status[0..self.host_status_len])) return;
        const length = @min(message.len, self.host_status.len);
        @memcpy(self.host_status[0..length], message[0..length]);
        self.host_status_len = length;
        self.status("{s}", .{message});
    }

    /// Let extensions supply panels. The host outlives the app in `run`.
    pub fn attachHost(self: *App, host: *Host) void {
        self.host = host;
    }

    /// Draw the panel an extension registered for a named region.
    ///
    /// The interface offers rectangles and the extension fills them: the `lanes`
    /// region is the agent list and `transcript` is the space below it. A panel
    /// is asked for its description on every frame it is drawn, so a panel that
    /// shows live state stays correct without an invalidation protocol, and a
    /// panel that throws simply contributes nothing.
    fn drawPanel(self: *App, r: *Renderer, frame: std.mem.Allocator, region: []const u8, bounds: Rect) !bool {
        const host = self.host orelse return false;
        const description = (host.panelDescription(region, bounds.w, bounds.h) catch |err| {
            std.log.err("panel {s}: {s}", .{ region, @errorName(err) });
            return false;
        }) orelse return false;
        defer self.allocator.free(description);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, description, .{}) catch |err| {
            std.log.err("panel {s}: {s}", .{ region, @errorName(err) });
            return false;
        };
        defer parsed.deinit();
        self.panel_tree.parse(parsed.value) catch |err| {
            std.log.err("panel {s}: {s}", .{ region, @errorName(err) });
            return false;
        };
        self.panel_tree.build(self.char_width, self.line_height) catch |err| {
            std.log.err("panel {s}: {s}", .{ region, @errorName(err) });
            return false;
        };
        self.panel_tree.layout(bounds.w, bounds.h);
        // A panel is confined to the region it fills: a long path in a narrow
        // column must not spill into the document beside it.
        const previous_clip = r.clip;
        r.clip = bounds;
        defer r.clip = previous_clip;
        try self.panel_tree.render(r, frame, bounds.x, bounds.y);
        var targets: std.ArrayListUnmanaged(ext_ui.Tree.Target) = .empty;
        defer targets.deinit(self.allocator);
        try self.panel_tree.collectTargets(&targets, self.allocator, bounds.x, bounds.y);
        for (targets.items) |target| {
            const id = try self.allocator.dupe(u8, target.id);
            errdefer self.allocator.free(id);
            if (target.focusable) try self.focus_order.append(self.allocator, self.panel_nodes.items.len);
            try self.panel_nodes.append(self.allocator, .{
                .panel = region,
                .id = id,
                .bounds = .{ .x = target.bounds.x, .y = target.bounds.y, .w = target.bounds.w, .h = target.bounds.h },
                .focusable = target.focusable,
            });
        }
        try self.panel_rects.append(self.allocator, .{ .name = region, .bounds = bounds });
        if (self.focus == .panels) try self.drawFocusRing(r);
        return true;
    }

    /// Forget the panels of the previous frame. Drawing refills both lists.
    fn beginPanels(self: *App) void {
        self.panel_rects.clearRetainingCapacity();
        for (self.panel_nodes.items) |node| self.allocator.free(node.id);
        self.panel_nodes.clearRetainingCapacity();
        self.focus_order.clearRetainingCapacity();
    }

    /// Outline the node the keyboard is on, so focus is visible rather than
    /// only internal state.
    fn drawFocusRing(self: *App, r: *Renderer) !void {
        const target = self.focusedTarget() orelse return;
        const box = target.bounds;
        const thickness: f32 = 2;
        try r.rect(.{ .x = box.x, .y = box.y, .w = box.w, .h = thickness }, theme.accent);
        try r.rect(.{ .x = box.x, .y = box.y + box.h - thickness, .w = box.w, .h = thickness }, theme.accent);
        try r.rect(.{ .x = box.x, .y = box.y, .w = thickness, .h = box.h }, theme.accent);
        try r.rect(.{ .x = box.x + box.w - thickness, .y = box.y, .w = thickness, .h = box.h }, theme.accent);
    }

    /// Route a click to the panel that was drawn under it. The description is
    /// re-read rather than cached, so hit testing needs no second copy of the
    /// layout: a click is rare enough to pay for one parse.
    fn clickPanel(self: *App, x: f32, y: f32) bool {
        const host = self.host orelse return false;
        const node = self.nodeAtPoint(x, y) orelse return false;
        self.setPanelFocus(x, y);
        host.dispatch("click", .{ .panel = node.panel, .id = node.id, .x = x, .y = y });
        return true;
    }

    /// Give the keyboard to the panel that was clicked, focusing the node under
    /// the pointer when one is focusable.
    fn setPanelFocus(self: *App, x: f32, y: f32) void {
        self.focus = .panels;
        const node = self.nodeAtPoint(x, y) orelse return;
        if (!node.focusable) return;
        for (self.focus_order.items, 0..) |node_index, position| {
            if (&self.panel_nodes.items[node_index] == &node) {
                self.panel_focus = position;
                return;
            }
        }
    }

    fn focusedTarget(self: *const App) ?PanelNode {
        if (self.focus_order.items.len == 0) return null;
        const index = self.focus_order.items[self.panel_focus % self.focus_order.items.len];
        return self.panel_nodes.items[index];
    }

    /// Topmost named node under a point. Nodes are collected in document order,
    /// so a later one is drawn over an earlier one and wins.
    fn nodeAtPoint(self: *const App, x: f32, y: f32) ?PanelNode {
        var index = self.panel_nodes.items.len;
        while (index > 0) {
            index -= 1;
            const node = self.panel_nodes.items[index];
            if (node.bounds.contains(x, y)) return node;
        }
        return null;
    }

    /// Tell an extension when the pointer moves onto or off one of its nodes.
    /// Only a change is reported, so a handler does not run for every motion.
    fn hoverPanel(self: *App, x: f32, y: f32) void {
        const host = self.host orelse return;
        const node = self.nodeAtPoint(x, y);
        const id = if (node) |found| found.id else "";
        if (std.mem.eql(u8, id, self.hover_id.items)) return;
        self.hover_id.clearRetainingCapacity();
        self.hover_id.appendSlice(self.allocator, id) catch return;
        if (node) |found| {
            host.dispatch("hover", .{ .panel = found.panel, .id = found.id, .x = x, .y = y });
            std.log.debug("hover {s} {s}", .{ found.panel, found.id });
        }
    }

    /// Send a key to the focused panel node. Tab and Escape belong to the
    /// interface, because they have to work whether or not an extension is
    /// listening for keys.
    fn panelKey(self: *App, keycode: c.SDL_Keycode, shift: bool) void {
        const host = self.host orelse return;
        switch (keycode) {
            c.SDLK_ESCAPE => {
                self.focus = .editor;
                return;
            },
            c.SDLK_TAB => {
                const count = self.focus_order.items.len;
                if (count > 0) {
                    self.panel_focus = if (shift) (self.panel_focus + count - 1) % count else (self.panel_focus + 1) % count;
                }
                return;
            },
            else => {},
        }
        const target = self.focusedTarget() orelse return;
        if (keycode == c.SDLK_RETURN or keycode == c.SDLK_SPACE) {
            host.dispatch("activate", .{ .panel = target.panel, .id = target.id });
            return;
        }
        host.dispatch("key", .{ .panel = target.panel, .id = target.id, .key = std.mem.span(c.SDL_GetKeyName(keycode)) });
    }

    /// Current status bar message, for reporting and tests.
    pub fn message_(self: *const App) []const u8 {
        return self.message[0..self.message_len];
    }

    /// Center of the first focusable node of a named panel. The panel owns its
    /// layout, so this asks the focus order rather than guessing coordinates.
    pub fn panelFocusPoint(self: *const App, name: []const u8) ?struct { x: f32, y: f32 } {
        for (self.focus_order.items) |index| {
            const node = self.panel_nodes.items[index];
            if (!std.mem.eql(u8, node.panel, name)) continue;
            return .{ .x = node.bounds.x + node.bounds.w / 2, .y = node.bounds.y + node.bounds.h / 2 };
        }
        return null;
    }

    /// Move the pointer, for the hover exercise.
    pub fn hoverPoint(self: *const App, name: []const u8) ?struct { x: f32, y: f32 } {
        for (self.panel_nodes.items) |node| {
            if (!std.mem.eql(u8, node.panel, name)) continue;
            return .{ .x = node.bounds.x + node.bounds.w / 2, .y = node.bounds.y + node.bounds.h / 2 };
        }
        return null;
    }

    /// A point in the first drawn panel, for the click exercise.
    pub fn firstPanelPoint(self: *const App) ?struct { x: f32, y: f32 } {
        const panel = if (self.panel_rects.items.len > 0) self.panel_rects.items[0] else return null;
        return .{ .x = panel.bounds.x + 60, .y = panel.bounds.y + 12 };
    }

    /// A point in the first row of a named region's panel, for the click
    /// exercise. A list starts at its top-left, so this lands on the first row
    /// rather than in the gap between rows.
    pub fn panelPoint(self: *const App, name: []const u8) ?struct { x: f32, y: f32 } {
        for (self.panel_rects.items) |panel| {
            if (std.mem.eql(u8, panel.name, name)) {
                return .{ .x = panel.bounds.x + 60, .y = panel.bounds.y + 12 };
            }
        }
        return null;
    }

    fn copySelection(self: *App) !void {
        if (self.focus != .editor) return;
        // Use a fresh snapshot because the cached frame can precede this event.
        const bytes = try self.workspace.activeDocument().snapshot(self.allocator);
        defer self.allocator.free(bytes);
        const range = self.selectedRange() orelse return;
        const z = try self.allocator.dupeSentinel(u8, bytes[range.start..range.end], 0);
        defer self.allocator.free(z);
        if (!c.SDL_SetClipboardText(z.ptr)) return error.Clipboard;
    }

    fn mouseDown(self: *App, x: f32, y: f32) !void {
        if (self.overlay != .none) return;
        // A divider is the first thing the pointer can mean: everything else
        // lives inside a dock, and the line between two of them belongs to
        // neither.
        if (self.dividerAt(x, y)) |divider| {
            self.dragging_divider = divider;
            return;
        }
        // The terminal's own strip belongs to the interface rather than to the
        // shell: a tab is not a click the program gets to see.
        if (self.terminalOpen() and self.geometry.terminal.contains(x, y)) {
            if (self.terminalTabAt(x, y)) |hit| {
                switch (hit) {
                    .select => |index| self.shells.select(index),
                    .close => |index| {
                        self.shells.select(index);
                        self.closeTerminalTab();
                    },
                    .new_tab => try self.newTerminalTab(),
                }
                return;
            }
            self.focus = .terminal;
            // A drag from here selects the screen's text, unless the program
            // asked for the mouse, in which case the pointer is its business.
            if (self.activeTerminal()) |terminal| {
                if (!terminal.wantsMouse()) {
                    const cell = self.terminalCell(x, y);
                    self.terminal_selection = .{ .anchor = cell, .cursor = cell };
                    self.terminal_dragging = true;
                }
            }
            return;
        }
        // The dock's own switch and rows belong to the interface, so they are
        // answered before any panel is offered the click. The files view is a
        // panel; the runs view is this.
        const dock = self.geometry.explorer;
        if (dock.w > 0 and dock.contains(x, y)) {
            if (y < dock.y + 26) {
                self.dock = if (x < dock.x + 70) .files else .runs;
                return;
            }
            if (self.dock == .files) {
                const step = self.line_height;
                const row = @as(usize, @intFromFloat(@max(0, y - dock.y - 34) / step)) + self.tree_first;
                if (self.files.visibleAt(row)) |node| {
                    if (node.folder) {
                        try self.files.toggle(node.path);
                    } else {
                        const full = try std.fs.path.join(self.allocator, &.{ self.workspace.root, node.path });
                        defer self.allocator.free(full);
                        try self.openFile(full);
                    }
                }
                return;
            }
            if (self.dock == .runs) {
                // The inbox sits above the runs, and answering it is a keystroke
                // rather than a click: what a row can do here is select its run.
                var inbox: std.ArrayList(Decision) = .empty;
                defer inbox.deinit(self.allocator);
                self.decisions(&inbox) catch {};
                const lead: f32 = if (inbox.items.len > 0) 18 + @as(f32, @floatFromInt(inbox.items.len)) * 38 + 28 else 0;
                const offset = y - dock.y - 36 - lead;
                if (offset >= 0) {
                    const index: usize = @intFromFloat(offset / 48);
                    if (index < self.runs.items.len) {
                        self.run_index = index;
                        self.status("Run {s} selected.", .{self.runs.items[index].name});
                    }
                }
                return;
            }
        }
        if (self.clickPanel(x, y)) return;
        const g = self.geometry;
        if (g.activity.contains(x, y)) {
            if (y < 105) self.sidebar = !self.sidebar else self.focus = .prompt;
        } else if (g.agents.contains(x, y)) {
            try self.inspectorClick(x, y);
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
            self.workspace.activeDocument().cursor = self.positionAt(x, y);
            self.selection_anchor = self.workspace.activeDocument().cursor;
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
        const doc = self.workspace.activeDocument();
        var pos: usize = if (line >= doc.lineCount()) doc.buffer.len() else doc.lineStartAt(line);
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
                        7 => try self.startRun(),
                        8 => self.perspective = if (self.perspective == .review) .code else .review,
                        9 => self.dock = if (self.dock == .runs) .files else .runs,
                        10 => self.perspective = if (self.perspective == .compose) .code else .compose,
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
        self.frame_count += 1;
        self.syncHostStatus();
        // Every region is drawn once per frame, so the lists they fill start
        // empty here rather than part way through.
        self.beginPanels();
        try self.publishSnapshot(frame);
        self.char_width = r.atlas.advance;
        self.line_height = r.atlas.line_height;
        self.geometry = layout.Layout.calculateResized(
            r.width,
            r.height,
            self.sidebar,
            .{ .line_height = self.line_height, .char_width = self.char_width },
            if (self.terminalOpen()) self.terminal_fraction else 0,
            self.resize,
        );
        const g = self.geometry;
        try r.rect(.{ .x = 0, .y = 0, .w = r.width, .h = r.height }, theme.background);

        try r.text(116, 11, "/ agent-native workspace", theme.muted);
        try r.text(@max(400, r.width - 174), 11, "SDL3 GPU / ACP", theme.accent);
        _ = try self.drawPanel(r, frame, "activity", g.activity);
        if (g.explorer.w > 0) {
            if (self.dock == .runs) {
                try self.drawRuns(r, frame);
            } else {
                // The navigator is native: a file tree is not something to
                // describe to the renderer, it is something the renderer knows
                // how to draw.
                try self.drawExplorerTree(r);
            }
            try self.drawDockSwitch(r);
        }
        switch (self.perspective) {
            .code => try self.drawEditor(r, frame),
            .review => try self.drawReview(r, frame),
            .compose => try self.drawCompose(r, frame),
        }
        if (self.terminalOpen()) try self.drawTerminal(r);
        if (self.terminalOpen()) try self.drawTerminalTabs(r);
        try self.drawInspector(r, frame);
        r.clip = .{ .x = 0, .y = 0, .w = r.width, .h = r.height };
        try r.rect(g.status, theme.selected);
        _ = try self.drawPanel(r, frame, "status", g.status);
        if (self.overlay != .none) try self.drawOverlay(r);
    }

    fn cursorLocation(self: *App) struct { line: usize, column: usize } {
        const doc = self.workspace.activeDocument();
        const line = doc.lineOf(doc.cursor);
        var pos = doc.lineStartAt(line);
        var col: usize = 0;
        while (pos < doc.cursor) : (pos = doc.next(pos)) {
            const byte = doc.buffer.byteAt(pos);
            col += if (byte == '\t') @as(usize, 4) else 1;
        }
        return .{ .line = line, .column = col };
    }

    fn switchBuffer(self: *App, forward: bool) void {
        self.workspace.cycle(forward);
        self.cached_revision = null;
        self.first_line = 0;
        self.first_column = 0;
        self.selection_anchor = null;
    }

    fn drawEditor(self: *App, r: *Renderer, frame: std.mem.Allocator) !void {
        const bounds = self.geometry.editor;
        r.clip = bounds;
        try r.rect(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = 36 }, theme.panel);
        // Tabs and the line below them are panels an extension fills; the editor
        // itself keeps drawing the text, because that is the document rather
        // than chrome around it.
        _ = try self.drawPanel(r, frame, "tabs", .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = 36 });

        const loc = self.cursorLocation();
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
        const lang = if (self.workspace.activePath()) |path| highlight.Language.detect(path) else .zig;
        var scan: highlight.Scanner = .{ .language = lang };
        var lines = std.mem.splitScalar(u8, self.cached, '\n');
        var line_no: usize = 0;
        var offset: usize = 0;
        while (lines.next()) |line| {
            defer {
                line_no += 1;
                offset += line.len + 1;
            }
            if (line_no < self.first_line) {
                scan.scanLine(line);
                continue;
            }
            if (line_no >= self.first_line + rows + 1) break;
            const y = viewport.y + 4 + @as(f32, @floatFromInt(line_no - self.first_line)) * self.line_height;
            if (line_no == loc.line) try r.rect(.{ .x = viewport.x, .y = y, .w = viewport.w, .h = self.line_height }, theme.panel);
            if (self.hasDiagnostic(line_no)) try r.rect(.{ .x = viewport.x, .y = y, .w = 3, .h = self.line_height }, theme.red);
            var number_buf: [24]u8 = undefined;
            const number = try std.fmt.bufPrint(&number_buf, "{d}", .{line_no + 1});
            try r.text(viewport.x + 46 - @as(f32, @floatFromInt(number.len)) * self.char_width, y, number, theme.muted);
            r.clip = .{ .x = viewport.x + 56, .y = viewport.y, .w = @max(0, viewport.w - 56), .h = viewport.h };
            var pos: usize = 0;
            var column: usize = 0;
            while (pos < line.len) {
                const cp = text.decode(line, pos);
                const color = scan.color(line, pos);
                const cells: usize = if (cp == '\t') 4 else 1;
                if (column + cells >= self.first_column) {
                    const x = viewport.x + 60 + (@as(f32, @floatFromInt(column)) - @as(f32, @floatFromInt(self.first_column))) * self.char_width;
                    if (x < viewport.x + viewport.w) {
                        if (selection) |range| {
                            if (offset + pos >= range.start and offset + pos < range.end) try r.rect(.{ .x = x, .y = y, .w = self.char_width * @as(f32, @floatFromInt(cells)), .h = self.line_height }, theme.selected);
                        }
                        if (cp != '\t' and cp != '\r') _ = try r.glyphAt(x, y + r.atlas.ascent, cp, color);
                    }
                }
                pos = text.next(line, pos);
                column += cells;
            }
            scan.endLine();
            r.clip = viewport;
        }
        // Half a second at the sixty frames a second the loop targets.
        if (self.focus == .editor and (self.frame_count / 30) % 2 == 0 and loc.line >= self.first_line and loc.line < self.first_line + rows and loc.column >= self.first_column) {
            try r.rect(.{ .x = viewport.x + 60 + @as(f32, @floatFromInt(loc.column - self.first_column)) * self.char_width, .y = viewport.y + 4 + @as(f32, @floatFromInt(loc.line - self.first_line)) * self.line_height, .w = 2, .h = self.line_height }, theme.accent);
        }
        // In-progress IME composition, drawn at the cursor with an underline.
        if (self.preedit.text.items.len > 0 and loc.line >= self.first_line and loc.line < self.first_line + rows) {
            const x = viewport.x + 60 + (@as(f32, @floatFromInt(loc.column)) - @as(f32, @floatFromInt(self.first_column))) * self.char_width;
            const y = viewport.y + 4 + @as(f32, @floatFromInt(loc.line - self.first_line)) * self.line_height;
            // The segment the input method has selected sits behind the text,
            // so the composition shows which part a further keypress replaces.
            const composing = self.preedit.selectionCells();
            if (composing.len > 0) {
                try r.rect(.{ .x = x + self.char_width * @as(f32, @floatFromInt(composing.start)), .y = y, .w = self.char_width * @as(f32, @floatFromInt(composing.len)), .h = self.line_height }, theme.selected);
            }
            try r.text(x, y, self.preedit.text.items, theme.amber);
            try r.rect(.{ .x = x, .y = y + self.line_height - 3, .w = self.char_width * @as(f32, @floatFromInt(self.preedit.cellCount())), .h = 2 }, theme.amber);
        }
    }

    // ---- terminal ----------------------------------------------------------

    /// Open or close the shell dock. The shell starts on first use and keeps
    /// running while the dock is closed, so closing it is not killing it.
    pub fn toggleTerminal(self: *App) !void {
        // Whether there is anything to show and whether it is on screen are
        // two questions. Asking the second one first reads "the dock is put
        // away" as "there are no sessions", and answers by starting another
        // shell every time the key is pressed.
        if (self.shells.count() == 0) return self.newTerminalTab();
        self.terminal_shown = !self.terminal_shown;
        if (self.terminal_shown) {
            self.status("Terminal shown.", .{});
        } else {
            if (self.focus == .terminal) self.focus = .editor;
            self.status("Terminal hidden. Ctrl+` brings it back.", .{});
        }
    }

    /// Whether the dock is on screen: there is a session to show and the dock
    /// has not been put away.
    pub fn terminalOpen(self: *const App) bool {
        return self.terminal_shown and self.shells.count() > 0;
    }

    fn activeTerminal(self: *App) ?*vt.Terminal {
        const session = self.shells.activeSession() orelse return null;
        return &session.terminal;
    }

    fn activeShell(self: *App) ?*pty.Pty {
        const session = self.shells.activeSession() orelse return null;
        return &session.shell;
    }

    /// Open another tab: a new shell with its own screen, which is what the
    /// reader means by asking for one.
    pub fn newTerminalTab(self: *App) !void {
        const shell_path: []const u8 = if (std.c.getenv("SHELL")) |value| std.mem.span(value) else "/bin/sh";
        var plan = shell_integration.integrate(self.allocator, shell_path) catch |err| {
            self.status("terminal: no command markers ({s})", .{@errorName(err)});
            return;
        };
        defer if (plan) |*value| value.deinit(self.allocator);
        if (plan) |value| {
            if (value.variable) |variable| {
                if (builtin.os.tag != .windows) {
                    const name = self.allocator.dupeSentinel(u8, variable.name, 0) catch null;
                    defer if (name) |bytes| self.allocator.free(bytes);
                    const setting = self.allocator.dupeSentinel(u8, variable.value, 0) catch null;
                    defer if (setting) |bytes| self.allocator.free(bytes);
                    if (name != null and setting != null) _ = c.setenv(name.?, setting.?, 1);
                }
            }
        }
        const shell_argv: []const []const u8 = if (plan) |value| value.argv else &.{shell_path};
        const index = self.shells.spawn(shell_argv, 80, 24, std.fs.path.basename(shell_path)) catch |err| {
            self.status("terminal: {s}", .{@errorName(err)});
            return;
        };
        // The editor polls the shell; a blocking read would stall the frame.
        if (self.shells.activeSession()) |session| session.shell.setNonBlocking() catch {};
        self.terminal_shown = true;
        self.focus = .terminal;
        self.status("Terminal {d} of {d}.", .{ index + 1, self.shells.count() });
    }

    /// Close the tab the reader is on. Closing the last one closes the dock,
    /// because a dock with nothing in it is a dock taking up room.
    pub fn closeTerminalTab(self: *App) void {
        if (self.shells.count() == 0) return;
        const closing = self.shells.active;
        self.shells.close(closing);
        if (self.shells.count() == 0) {
            if (self.focus == .terminal) self.focus = .editor;
            self.status("Terminal dock closed. Ctrl+` brings it back.", .{});
            return;
        }
        self.status("Terminal {d} of {d}.", .{ self.shells.active + 1, self.shells.count() });
    }

    /// Move the current tab one place along the strip.
    pub fn moveTerminalTab(self: *App, forward: bool) void {
        const count = self.shells.count();
        if (count < 2) return;
        const from = self.shells.active;
        const to = if (forward) @min(from + 1, count - 1) else (from -| 1);
        if (from == to) return;
        self.shells.move(from, to);
        self.status("Terminal {d} of {d}.", .{ self.shells.active + 1, count });
    }

    /// Which divider a point is on. The band is a few pixels either side,
    /// because a divider one pixel wide is a divider nobody can hit.
    pub fn dividerAt(self: *const App, x: f32, y: f32) ?Divider {
        const g = self.geometry;
        const grab: f32 = 4;
        if (g.explorer.w > 0 and y >= g.explorer.y and y < g.explorer.y + g.explorer.h and
            x >= g.explorer.x + g.explorer.w - grab and x <= g.explorer.x + g.explorer.w + grab)
            return .explorer;
        if (g.agents.w > 0 and y >= g.agents.y and y < g.agents.y + g.agents.h and
            x >= g.agents.x - grab and x <= g.agents.x + grab)
            return .agents;
        if (g.terminal.h > 0 and x >= g.terminal.x and x < g.terminal.x + g.terminal.w and
            y >= g.terminal.y - grab and y <= g.terminal.y + grab)
            return .terminal;
        return null;
    }

    /// Drag a divider to where the pointer is. The layout decides what that
    /// means: a drag past a limit lands on the limit.
    fn dragDivider(self: *App, divider: Divider, x: f32, y: f32) void {
        const g = self.geometry;
        switch (divider) {
            .explorer => self.resize.explorer = @max(0, x - g.explorer.x),
            .agents => self.resize.agents = @max(0, g.agents.x + g.agents.w - x),
            .terminal => {
                const body = @max(1, g.explorer.h);
                const above = g.terminal.y + g.terminal.h - y;
                self.terminal_fraction = @max(0.05, @min(0.9, above / body));
            },
        }
    }

    /// A cell the pointer is over, clamped to the screen.
    fn terminalCell(self: *App, x: f32, y: f32) vt.Terminal.Point {
        const bounds = self.geometry.terminal;
        const top = bounds.y + 26;
        const cell_x: u16 = @intFromFloat(@max(0, @floor((x - bounds.x - 4) / self.char_width)));
        const cell_y: u16 = @intFromFloat(@max(0, @floor((y - top - 4) / self.line_height)));
        return .{ .x = @min(cell_x, 200), .y = @min(cell_y, 200) };
    }

    /// What the pointer has dragged over in the terminal, if anything.
    pub const TerminalSelection = struct { anchor: vt.Terminal.Point, cursor: vt.Terminal.Point };

    /// Whether a cell is inside the selection, in reading order.
    fn terminalSelected(self: *const App, column: usize, row: usize) bool {
        const selection = self.terminal_selection orelse return false;
        const forward = selection.anchor.y < selection.cursor.y or
            (selection.anchor.y == selection.cursor.y and selection.anchor.x <= selection.cursor.x);
        const from = if (forward) selection.anchor else selection.cursor;
        const to = if (forward) selection.cursor else selection.anchor;
        const y: u16 = @intCast(row);
        const x: u16 = @intCast(column);
        if (y < from.y or y > to.y) return false;
        if (y == from.y and x < from.x) return false;
        if (y == to.y and x > to.x) return false;
        return true;
    }

    /// Copy what the pointer selected. A terminal's own Ctrl+C belongs to the
    /// program, so copying takes the shift, which is what every terminal does.
    pub fn copyTerminalSelection(self: *App) !void {
        const selection = self.terminal_selection orelse {
            self.status("Nothing is selected in the terminal.", .{});
            return;
        };
        const terminal = self.activeTerminal() orelse return;
        const picked = try terminal.select(self.allocator, selection.anchor, selection.cursor);
        defer self.allocator.free(picked);
        if (picked.len == 0) {
            self.status("Nothing is selected in the terminal.", .{});
            return;
        }
        const terminated = try self.allocator.dupeSentinel(u8, picked, 0);
        defer self.allocator.free(terminated);
        if (!c.SDL_SetClipboardText(terminated.ptr)) {
            self.status("terminal: could not reach the clipboard", .{});
            return;
        }
        self.status("Copied {d} byte(s) from the terminal.", .{picked.len});
    }

    /// The tab strip above the terminal's screen. A tab per shell, the one
    /// showing marked, and a way to add another and to close one.
    fn drawTerminalTabs(self: *App, r: *Renderer) !void {
        const bounds = self.geometry.terminal;
        const strip: Rect = .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = layout.Layout.terminal_strip_height };
        r.clip = strip;
        try r.rect(strip, theme.panel);
        var x = strip.x + 6;
        const count = self.shells.count();
        for (0..count) |index| {
            const title = self.shells.titleAt(index) orelse continue;
            const active = index == self.shells.active;
            const width: f32 = @min(strip.w - (x - strip.x) - 40, 150);
            if (width < 40) break;
            if (active) try r.rect(.{ .x = x, .y = strip.y + 3, .w = width, .h = strip.h - 6 }, theme.raised);
            var scratch: [256]u8 = undefined;
            const room: usize = @intFromFloat(@max(2, (width - 34) / r.atlas.advance));
            const label = wrap.elide(&scratch, title, room);
            try r.text(x + 8, strip.y + 7, label, if (active) theme.accent else theme.muted);
            // A close box on every tab, and on the active one it is where a
            // reader looks for it first.
            try r.text(x + width - 16, strip.y + 7, "×", if (active) theme.text else theme.muted);
            x += width + 4;
        }
        try r.text(x + 4, strip.y + 7, "+", theme.accent);
    }

    /// Which tab, close box, or new-tab control a point in the strip is on.
    /// Null when the point is in the strip but on none of them.
    pub fn terminalTabAt(self: *const App, x: f32, y: f32) ?TerminalHit {
        const bounds = self.geometry.terminal;
        if (bounds.w <= 0 or y < bounds.y or y >= bounds.y + 26) return null;
        var cursor = bounds.x + 6;
        for (0..self.shells.count()) |index| {
            const width: f32 = @min(bounds.x + bounds.w - cursor - 40, 150);
            if (width < 40) break;
            if (x >= cursor and x < cursor + width) {
                if (x >= cursor + width - 24) return .{ .close = index };
                return .{ .select = index };
            }
            cursor += width + 4;
        }
        if (x >= cursor and x < cursor + 24) return .new_tab;
        return null;
    }

    pub const TerminalHit = union(enum) {
        select: usize,
        close: usize,
        new_tab,
    };

    /// Move bytes one way and the screen the other: the shell's output into the
    /// emulator, and the size the dock gives the emulator back to the shell.
    fn pumpTerminal(self: *App) void {
        const shell = self.activeShell() orelse return;
        const terminal = self.activeTerminal() orelse return;
        self.terminal_read.clearRetainingCapacity();
        while (true) {
            self.terminal_read.ensureUnusedCapacity(self.allocator, 4096) catch break;
            const count = shell.readOutput(self.terminal_read.unusedCapacitySlice()) catch break;
            if (count == 0) break;
            self.terminal_read.items.len += count;
        }
        if (self.terminal_read.items.len != 0) terminal.write(self.terminal_read.items);
        if (self.terminalOpen()) {
            const bounds = layout.Layout.terminalScreen(self.geometry.terminal);
            const cols: u16 = @intFromFloat(@max(2, @floor((bounds.w - 8) / self.char_width)));
            const rows: u16 = @intFromFloat(@max(1, @floor((bounds.h - 8) / self.line_height)));
            if (cols != terminal.cols() or rows != terminal.rows()) {
                // The emulator's size and the shell's are two different
                // terminals until this says so: without it the program keeps
                // laying its output out for whatever it was told at birth.
                terminal.resize(cols, rows, @intFromFloat(@round(self.char_width)), @intFromFloat(@round(self.line_height))) catch |err| {
                    self.status("terminal: cannot resize ({s})", .{@errorName(err)});
                    return;
                };
                self.shells.resizeActive(cols, rows);
            }
        }
        terminal.update() catch {};
    }

    /// Draw the grid the shell produced: each cell's background, then its
    /// glyph, then the cursor where the program put it.
    fn drawTerminal(self: *App, r: *Renderer) !void {
        const terminal = self.activeTerminal() orelse return;
        const bounds = layout.Layout.terminalScreen(self.geometry.terminal);
        if (bounds.h <= 0 or bounds.w <= 0) return;
        // The emulator owns the dock's colors; the editor's theme is the
        // fallback for the case where it cannot answer at all.
        const colors = terminal.colors() catch null;
        const background = if (colors) |value| rgbColor(value.background) else theme.background;
        const foreground = if (colors) |value| rgbColor(value.foreground) else theme.text;
        r.clip = bounds;
        try r.rect(bounds, background);

        const Painter = struct {
            r: *Renderer,
            app: *const App,
            origin_x: f32,
            origin_y: f32,
            char_width: f32,
            line_height: f32,
            ascent: f32,
            foreground: theme.Color,
            palette: [256]theme.Color,

            fn color(painter: *@This(), value: ghostty.GhosttyStyleColor, fallback: theme.Color) theme.Color {
                return switch (value.tag) {
                    ghostty.GHOSTTY_STYLE_COLOR_RGB => rgbColor(value.value.rgb),
                    ghostty.GHOSTTY_STYLE_COLOR_PALETTE => painter.palette[value.value.palette],
                    else => fallback,
                };
            }

            fn visit(painter: *@This(), row: u16, cells: []const vt.Terminal.Cell) anyerror!void {
                const y = painter.origin_y + @as(f32, @floatFromInt(row)) * painter.line_height;
                for (cells, 0..) |cell, column| {
                    const x = painter.origin_x + @as(f32, @floatFromInt(column)) * painter.char_width;
                    var cell_background = painter.color(cell.style.bg_color, painter.palette[0]);
                    var cell_foreground = painter.color(cell.style.fg_color, painter.foreground);
                    if (cell.style.inverse) {
                        const swap = cell_background;
                        cell_background = cell_foreground;
                        cell_foreground = swap;
                    }
                    if (!std.mem.eql(f32, &cell_background, &painter.palette[0])) {
                        try painter.r.rect(.{ .x = x, .y = y, .w = painter.char_width, .h = painter.line_height }, cell_background);
                    }
                    // What the pointer dragged over, under the text it covers.
                    if (painter.app.terminalSelected(column, row)) {
                        try painter.r.rect(.{ .x = x, .y = y, .w = painter.char_width, .h = painter.line_height }, theme.selected);
                    }
                    if (cell.style.underline != 0) {
                        try painter.r.rect(.{ .x = x, .y = y + painter.line_height - 2, .w = painter.char_width, .h = 1 }, cell_foreground);
                    }
                    if (cell.codepoints.len == 0) continue;
                    // A grapheme's later codepoints are combining marks; the
                    // atlas maps codepoints, so the base is what it can draw.
                    const codepoint = std.math.cast(u21, cell.codepoints[0]) orelse continue;
                    // The atlas holds one upright face, so italic is a lean and
                    // bold is a second strike a fraction of a pixel across:
                    // the usual shapes for a terminal with no second font.
                    const baseline = y + painter.ascent;
                    const lean: f32 = if (cell.style.italic) painter.ascent * 0.22 else 0;
                    _ = try painter.r.glyphShearedAt(x, baseline, codepoint, cell_foreground, lean);
                    if (cell.style.bold) {
                        _ = try painter.r.glyphShearedAt(x + 0.6, baseline, codepoint, cell_foreground, lean);
                    }
                }
            }
        };

        var painter: Painter = .{
            .r = r,
            .app = self,
            .origin_x = bounds.x + 4,
            .origin_y = bounds.y + 4,
            .char_width = self.char_width,
            .line_height = self.line_height,
            .ascent = r.atlas.ascent,
            .foreground = foreground,
            .palette = if (colors) |value| paletteColors(value.palette, background) else paletteFallback(background),
        };
        try terminal.visitRows(&painter, Painter.visit);

        const cursor = terminal.cursor();
        if (cursor.visible and self.focus == .terminal) {
            const x = painter.origin_x + @as(f32, @floatFromInt(cursor.x)) * self.char_width;
            const y = painter.origin_y + @as(f32, @floatFromInt(cursor.y)) * self.line_height;
            const color = if ((self.frame_count / 30) % 2 == 0) foreground else background;
            try r.rect(.{ .x = x, .y = y, .w = self.char_width, .h = self.line_height }, color);
        }
        // A bar only where there is history to place in it. The library
        // reports the area; the width and the thumb are the editor's.
        if (terminal.scrollbar() catch null) |bar| {
            if (bar.total > bar.len and bar.len > 0) {
                const track = Rect{ .x = bounds.x + bounds.w - 5, .y = bounds.y + 2, .w = 3, .h = bounds.h - 4 };
                try r.rect(track, theme.raised);
                const visible = @as(f32, @floatFromInt(bar.len)) / @as(f32, @floatFromInt(bar.total));
                const thumb_height = @max(track.h * visible, 14);
                const travelled = @as(f32, @floatFromInt(bar.offset)) / @as(f32, @floatFromInt(bar.total));
                try r.rect(.{ .x = track.x, .y = track.y + (track.h - thumb_height) * travelled, .w = track.w, .h = thumb_height }, theme.muted);
            }
        }
        terminal.markDrawn();
    }

    /// The shell wants the keys a terminal sends, not the editor's meanings.
    /// Printable keys arrive as text, so this covers the rest.
    fn terminalKey(self: *App, keycode: c.SDL_Keycode, ctrl: bool, shift: bool, alt: bool) !void {
        const terminal = self.activeTerminal() orelse return;
        const shell = self.activeShell() orelse return;
        const ghostty_key: ghostty.GhosttyKey = switch (keycode) {
            c.SDLK_UP => ghostty.GHOSTTY_KEY_ARROW_UP,
            c.SDLK_DOWN => ghostty.GHOSTTY_KEY_ARROW_DOWN,
            c.SDLK_LEFT => ghostty.GHOSTTY_KEY_ARROW_LEFT,
            c.SDLK_RIGHT => ghostty.GHOSTTY_KEY_ARROW_RIGHT,
            c.SDLK_HOME => ghostty.GHOSTTY_KEY_HOME,
            c.SDLK_END => ghostty.GHOSTTY_KEY_END,
            c.SDLK_PAGEUP => ghostty.GHOSTTY_KEY_PAGE_UP,
            c.SDLK_PAGEDOWN => ghostty.GHOSTTY_KEY_PAGE_DOWN,
            c.SDLK_INSERT => ghostty.GHOSTTY_KEY_INSERT,
            c.SDLK_DELETE => ghostty.GHOSTTY_KEY_DELETE,
            c.SDLK_BACKSPACE => ghostty.GHOSTTY_KEY_BACKSPACE,
            c.SDLK_RETURN => ghostty.GHOSTTY_KEY_ENTER,
            c.SDLK_TAB => ghostty.GHOSTTY_KEY_TAB,
            c.SDLK_ESCAPE => ghostty.GHOSTTY_KEY_ESCAPE,
            c.SDLK_F1 => ghostty.GHOSTTY_KEY_F1,
            c.SDLK_F2 => ghostty.GHOSTTY_KEY_F2,
            c.SDLK_F3 => ghostty.GHOSTTY_KEY_F3,
            c.SDLK_F4 => ghostty.GHOSTTY_KEY_F4,
            c.SDLK_F5 => ghostty.GHOSTTY_KEY_F5,
            c.SDLK_F6 => ghostty.GHOSTTY_KEY_F6,
            c.SDLK_F7 => ghostty.GHOSTTY_KEY_F7,
            c.SDLK_F8 => ghostty.GHOSTTY_KEY_F8,
            c.SDLK_F9 => ghostty.GHOSTTY_KEY_F9,
            c.SDLK_F10 => ghostty.GHOSTTY_KEY_F10,
            c.SDLK_F11 => ghostty.GHOSTTY_KEY_F11,
            c.SDLK_F12 => ghostty.GHOSTTY_KEY_F12,
            else => return,
        };
        const bytes = terminal.encodeKey(
            @intCast(ghostty_key),
            .press,
            .{ .shift = shift, .ctrl = ctrl, .alt = alt },
            "",
            null,
            &self.terminal_encode,
        ) catch return;
        if (bytes.len == 0) return;
        shell.writeInput(bytes) catch {};
    }

    /// Typed characters go to the shell as themselves: bracketed paste is for
    /// pasting, and a program that asked for it would misread every keystroke.
    fn terminalText(self: *App, bytes: []const u8) !void {
        const shell = self.activeShell() orelse return;
        shell.writeInput(bytes) catch {};
    }

    /// Paste travels through the emulator so the shell sees what it asked for:
    /// bracketed wrapping when it enabled it, and its control bytes stripped.
    fn terminalPaste(self: *App, bytes: []const u8) !void {
        const terminal = self.activeTerminal() orelse return;
        const shell = self.activeShell() orelse return;
        const encoded = terminal.encodePaste(bytes, &self.terminal_encode) catch return;
        if (encoded.len == 0) return;
        shell.writeInput(encoded) catch {};
    }

    fn paletteColors(palette: [256]ghostty.GhosttyColorRgb, fallback: theme.Color) [256]theme.Color {
        var colors: [256]theme.Color = @splat(fallback);
        for (&colors, 0..) |*entry, index| entry.* = rgbColor(palette[index]);
        return colors;
    }

    /// The visible screen as text, one line per row. A display is not needed to
    /// see what a shell produced, so exercises and tests assert on this.
    pub fn terminalScreen(self: *App, a: std.mem.Allocator) !?[]u8 {
        const terminal = self.activeTerminal() orelse return null;
        const Collector = struct {
            allocator: std.mem.Allocator,
            text: std.ArrayList(u8) = .empty,
            fn visit(collector: *@This(), row: u16, cells: []const vt.Terminal.Cell) anyerror!void {
                _ = row;
                var encoded: [8]u8 = undefined;
                for (cells) |cell| {
                    if (cell.codepoints.len == 0) {
                        try collector.text.append(collector.allocator, ' ');
                        continue;
                    }
                    const length = std.unicode.utf8Encode(@intCast(cell.codepoints[0]), &encoded) catch 0;
                    try collector.text.appendSlice(collector.allocator, encoded[0..length]);
                }
                try collector.text.append(collector.allocator, 0x0a);
            }
        };
        var collector: Collector = .{ .allocator = a };
        errdefer collector.text.deinit(a);
        try terminal.visitRows(&collector, Collector.visit);
        return try collector.text.toOwnedSlice(a);
    }

    /// A wheel over the terminal: the program running there gets it when it
    /// asked for mouse reporting, and otherwise it moves through scrollback.
    fn scrollTerminal(self: *App, lines: i32, x: f32, y: f32) void {
        const terminal = self.activeTerminal() orelse return;
        const bounds = self.geometry.terminal;
        const cell_x: u16 = @intFromFloat(@max(0, @floor((x - bounds.x - 4) / self.char_width)));
        const cell_y: u16 = @intFromFloat(@max(0, @floor((y - bounds.y - 4) / self.line_height)));
        if (terminal.wantsMouse()) {
            const button: vt.Terminal.MouseButton = if (lines < 0) .four else .five;
            const encoded = terminal.encodeMouse(.press, button, cell_x, cell_y, .{}, &self.terminal_encode) catch return;
            if (encoded.len != 0) {
                if (self.activeShell()) |shell| shell.writeInput(encoded) catch {};
            }
            return;
        }
        // `lines` is already the direction the wheel moved, and the emulator
        // reads a negative delta as upward into history. Negating it here turned
        // every upward scroll into a downward one.
        terminal.scroll(@intCast(lines));
    }

    /// Type into the terminal as if the keyboard had: the same path the keys
    /// take, minus the events.
    pub fn terminalInput(self: *App, bytes: []const u8) !void {
        try self.terminalText(bytes);
    }

    /// The palette a terminal with no emulator colors falls back on: the
    /// editor's own, so the dock still reads as part of the window.
    fn paletteFallback(fallback: theme.Color) [256]theme.Color {
        var palette: [256]theme.Color = undefined;
        for (&palette) |*entry| entry.* = fallback;
        return palette;
    }

    fn rgbColor(value: ghostty.GhosttyColorRgb) theme.Color {
        return .{
            @as(f32, @floatFromInt(value.r)) / 255.0,
            @as(f32, @floatFromInt(value.g)) / 255.0,
            @as(f32, @floatFromInt(value.b)) / 255.0,
            1,
        };
    }

    /// Rows the inspector offers: three kinds of context, then one destination
    /// per harness. A click toggles the first and pipes through the second,
    /// which is the whole interaction: select, switch on, pipe.
    const InspectorRow = union(enum) {
        context: usize,
        destination: usize,
    };

    fn inspectorRowAt(self: *App, y: f32) ?InspectorRow {
        const bounds = self.geometry.agents;
        const context_y = bounds.y + 46;
        const row_height = inspectorRowHeight(self.line_height);
        for (0..3) |index| {
            const row_y = context_y + @as(f32, @floatFromInt(index)) * row_height;
            if (y >= row_y and y < row_y + row_height) return .{ .context = index };
        }
        const pipe_y = context_y + 3 * row_height + 20;
        for (0..self.clients.len) |index| {
            const row_y = pipe_y + @as(f32, @floatFromInt(index)) * 26;
            if (y >= row_y and y < row_y + 26) return .{ .destination = index };
        }
        return null;
    }

    fn inspectorClick(self: *App, x: f32, y: f32) !void {
        _ = x;
        const row = self.inspectorRowAt(y) orelse return;
        switch (row) {
            .context => |index| {
                self.inspector_context[index] = !self.inspector_context[index];
                self.status("Context {s}.", .{if (self.inspector_context[index]) "attached" else "removed"});
            },
            .destination => |index| try self.pipeTo(index),
        }
    }

    /// Whether the inspector will carry one of its context rows. The click path
    /// and the prompt path both go through this, so a click that did not land
    /// is visible from outside.
    pub fn inspectorContext(self: *const App, index: usize) bool {
        return if (index < self.inspector_context.len and self.inspector_context[index]) true else false;
    }

    /// The drawn row of the first file in the navigator, so a caller outside the
    /// interface can exercise opening one without knowing how the tree is built.
    pub fn explorerFirstFileRow(self: *const App) ?usize {
        var seen: usize = 0;
        var found: ?usize = null;
        const Finder = struct {
            seen: *usize,
            found: *?usize,
            fn visit(finder: *@This(), node: *const tree_widget.Node) anyerror!void {
                if (finder.found.* == null and !node.folder) finder.found.* = finder.seen.*;
                finder.seen.* += 1;
            }
        };
        var finder: Finder = .{ .seen = &seen, .found = &found };
        self.files.visit(&finder, Finder.visit) catch return null;
        return found;
    }

    /// A point inside a navigator row, for callers outside the interface.
    pub fn explorerRowPoint(self: *const App, row: usize) ?struct { x: f32, y: f32 } {
        const bounds = self.geometry.explorer;
        if (bounds.w <= 0 or row < self.tree_first) return null;
        const offset = @as(f32, @floatFromInt(row - self.tree_first)) * self.line_height;
        return .{ .x = bounds.x + bounds.w - 20, .y = bounds.y + 42 + offset };
    }

    /// The clickable point of a context row, for callers outside the interface
    /// that need to exercise the inspector without a pointer device.
    pub fn inspectorRowPoint(self: *const App, index: usize) ?struct { x: f32, y: f32 } {
        if (index >= self.inspector_context.len) return null;
        const bounds = self.geometry.agents;
        if (bounds.w <= 0) return null;
        const y = bounds.y + 46 + @as(f32, @floatFromInt(index)) * 26;
        return .{ .x = bounds.x + 60, .y = y + 10 };
    }

    /// The run the inspector is about, if this session has started any.
    pub fn activeRun(self: *App) ?*runs.Run {
        if (self.runs.items.len == 0) return null;
        if (self.run_index >= self.runs.items.len) self.run_index = self.runs.items.len - 1;
        return &self.runs.items[self.run_index];
    }

    /// How many runs are waiting for a person to decide something. This is the
    /// number the navigator surfaces, because a run that needs nothing from
    /// anybody is not news.
    pub fn decisionsWaiting(self: *App) usize {
        var waiting: usize = 0;
        for (self.runs.items) |run| {
            if (run.state == .waiting_for_approval) waiting += 1;
        }
        return waiting;
    }

    /// The starter workflow. Starting a run needs no harness to be up, because
    /// a run is the task rather than the tool that happens to do it.
    pub fn startRun(self: *App) !void {
        const steps = [_]runs.Step{
            .{ .name = "plan", .produces = .plan, .action = .{ .agent = .{ .harness = 0, .request = "Produce an implementation plan for the code below." } } },
            .{ .name = "implement", .produces = .implementation, .action = .{ .agent = .{ .harness = 1, .request = "Implement the plan. Describe the change you made." } } },
            .{ .name = "review", .produces = .review, .action = .{ .agent = .{ .harness = 2, .request = "Review the implementation against the plan." } } },
        };
        var run = try runs.Run.init(self.allocator, std.fs.path.basename(self.workspace.activePath() orelse "workspace"), &steps);
        errdefer run.deinit();
        // What the run starts from is the code that was on screen, kept as the
        // artifact every later step can be traced back to.
        const bytes = try self.workspace.activeDocument().snapshot(self.allocator);
        defer self.allocator.free(bytes);
        try run.artifacts.append(self.allocator, .{
            .kind = .context,
            .source = try self.allocator.dupe(u8, "workspace"),
            .body = try self.allocator.dupe(u8, bytes),
        });
        try self.runs.append(self.allocator, run);
        self.run_index = self.runs.items.len - 1;
        self.dock = .runs;
        self.status("Run {s}: {d} steps.", .{ run.name, run.steps.len });
    }

    /// The state of a harness, for callers that have to wait for it.
    pub fn agentState(self: *const App, index: usize) Client.State {
        return self.clients[index].state;
    }

    /// How much a harness has said so far.
    pub fn agentTranscript(self: *const App, index: usize) usize {
        return self.clients[index].transcript.items.len;
    }

    /// What a harness has said, for reporting and tests.
    pub fn agentWords(self: *const App, index: usize) []const u8 {
        return self.clients[index].transcript.items;
    }

    /// The terminal's last command, as the shell reported it. Null when the
    /// shell reports nothing, which is not the same as an empty command: one is
    /// a terminal that does not know, the other is a command that did nothing.
    pub fn terminalCommand(self: *App, allocator: std.mem.Allocator) !?[]u8 {
        const terminal = self.activeTerminal() orelse return null;
        const result = (try terminal.lastCommand(allocator)) orelse return null;
        allocator.free(result.output);
        return result.command;
    }

    /// Whether a harness is up and able to take a turn.
    pub fn agentReady(self: *const App, index: usize) bool {
        if (index >= self.clients.len) return false;
        return self.clients[index].state == .ready;
    }

    /// Position of a harness by name, or null when this session has no such
    /// profile.
    pub fn agentIndex(self: *const App, name: []const u8) ?usize {
        for (self.clients, 0..) |client, index| {
            if (std.mem.eql(u8, client.preset.name, name)) return index;
        }
        return null;
    }

    /// Send the current step of the run to its harness. The step is marked
    /// running here and recorded when the harness finishes its turn: asking is
    /// not the same as being answered.
    pub fn runStep(self: *App) !void {
        const run = self.activeRun() orelse return error.NoRun;
        const step = run.current() orelse return error.RunFinished;
        switch (step.action) {
            .agent => |agent| {
                if (agent.harness >= self.clients.len) return error.NoSuchAgent;
                const client = &self.clients[agent.harness];
                if (client.state != .ready) return error.AgentNotReady;
                step.turns_mark = client.completed_turns;
                step.transcript_mark = client.transcript.items.len;
                const message = try run.promptFor(self.allocator, step, agent.request);
                defer self.allocator.free(message);
                try client.prompt(message);
                step.state = .running;
                self.status("Run {s}: {s} sent to {s}.", .{ run.name, step.name, client.preset.name });
            },
            .command => |argv| {
                // The command runs where the work is, and its exit status is
                // part of the artifact: a step that failed is not a step that
                // finished, and the run stops rather than feeding a hopeful
                // summary to the next step.
                var outcome = process.run(self.allocator, self.workspace.root, argv) catch |err| {
                    run.fail(step);
                    self.status("Run {s}: {s} could not run: {s}", .{ run.name, step.name, @errorName(err) });
                    return;
                };
                defer outcome.deinit(self.allocator);
                var body: std.ArrayList(u8) = .empty;
                defer body.deinit(self.allocator);
                for (argv, 0..) |word, index| {
                    if (index > 0) try body.append(self.allocator, ' ');
                    try body.appendSlice(self.allocator, word);
                }
                var header: [32]u8 = undefined;
                try body.appendSlice(self.allocator, try std.fmt.bufPrint(&header, "\nexit {d}\n", .{outcome.exit}));
                try body.appendSlice(self.allocator, outcome.stdout);
                if (outcome.stderr.len > 0) {
                    try body.appendSlice(self.allocator, "\n[stderr]\n");
                    try body.appendSlice(self.allocator, outcome.stderr);
                }
                try run.record(step, body.items);
                if (!outcome.ok()) {
                    run.fail(step);
                    self.status("Run {s}: {s} exited {d}.", .{ run.name, step.name, outcome.exit });
                } else {
                    self.status("Run {s}: {s} passed.", .{ run.name, step.name });
                }
            },
            .approval => {
                step.state = .running;
                run.state = .waiting_for_approval;
                self.status("Run {s}: {s} waits for you. Ctrl+Shift+A approves.", .{ run.name, step.name });
            },
        }
    }

    /// Record what a finished step produced. A turn that ended is not a
    /// verdict: the artifact is the text the harness returned, and what it
    /// means is for the next step or for the developer.
    fn advanceRun(self: *App) void {
        const run = self.activeRun() orelse return;
        const step = run.current() orelse return;
        if (step.state != .running) return;
        const harness = switch (step.action) {
            .agent => |agent| agent.harness,
            else => return,
        };
        if (harness >= self.clients.len) return;
        const client = &self.clients[harness];
        // The conversation is bounded, so an offset only means anything while
        // nothing has been dropped: a transcript shorter than the mark has
        // wrapped, and what remains is the tail.
        const from = if (client.transcript.items.len >= step.transcript_mark) step.transcript_mark else 0;
        const answer = client.transcript.items[from..];
        // A turn that finished is the signal; a lane that failed on the way is
        // not, because a harness may stumble and answer anyway. Only a lane
        // that is gone ends the step.
        const finished = client.completed_turns > step.turns_mark and answer.len > 0;
        if (!finished) {
            if (client.state == .failed or client.state == .offline) {
                std.log.err("run: {s} failed: client state={s} turns={d} mark={d} words={d}", .{
                    step.name, @tagName(client.state), client.completed_turns, step.turns_mark, answer.len,
                });
                run.fail(step);
                self.status("Run {s}: {s} failed.", .{ run.name, step.name });
            }
            return;
        }
        run.record(step, answer) catch |err| {
            self.status("Run {s}: {s}.", .{ run.name, @errorName(err) });
            return;
        };
        self.status("Run {s}: {s} finished.", .{ run.name, step.name });
    }

    /// Whether the run is waiting for a person to decide something.
    /// Why a change cannot be applied as it stands, or null when it can.
    /// A review that hides a stale change is worse than one that shows none:
    /// the developer is being asked to accept something that would not land.
    pub fn reviewObstacle(self: *App, index: usize) ?[]const u8 {
        const queue = &self.review;
        if (index >= queue.count()) return "no such change";
        const edit = queue.editAt(index);
        const current = self.workspace.bufferMatches(edit.path, edit.expected_revision) orelse return "the file is not open";
        if (!current) return "the file changed since this was proposed";
        return null;
    }

    /// Move the review selection down one change, stopping at the last: the
    /// list is what is waiting, and there is nothing past it.
    fn selectNextReview(self: *App) void {
        const count = self.review.count();
        if (count > 0 and self.review_selected + 1 < count) self.review_selected += 1;
    }

    /// The dock says which of two things it is navigating. Which one is a
    /// choice the developer makes, not a mode the interface decides for them:
    /// files are where the work is, runs are what is happening to it.
    fn drawDockSwitch(self: *App, r: *Renderer) !void {
        const bounds = self.geometry.explorer;
        r.clip = bounds;
        try r.rect(.{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = 26 }, theme.background);
        const waiting = self.decisionsWaiting();
        try r.text(bounds.x + 12, bounds.y + 8, "FILES", if (self.dock == .files) theme.accent else theme.muted);
        try r.text(bounds.x + 74, bounds.y + 8, "RUNS", if (self.dock == .runs) theme.accent else theme.muted);
        if (waiting > 0) {
            var label: [32]u8 = undefined;
            const words = try std.fmt.bufPrint(&label, "{d} to decide", .{waiting});
            try r.text(bounds.x + bounds.w - 88, bounds.y + 8, words, theme.amber);
        }
    }

    /// One thing waiting on a person, with what it belongs to. A decision that
    /// does not say which run it is about is a decision somebody has to go
    /// looking for.
    const Decision = struct {
        what: []const u8,
        scope: []const u8,
        key: []const u8,
    };

    /// Everything waiting on a person, decisions before routine progress: this
    /// is the inbox, and it is the first thing the dock shows.
    fn decisions(self: *App, out: *std.ArrayList(Decision)) !void {
        for (self.clients) |client| {
            if (client.permission != null) {
                try out.append(self.allocator, .{
                    .what = client.permissionTitle(),
                    .scope = client.preset.name,
                    .key = "Alt+Y / Alt+N",
                });
            }
        }
        for (self.runs.items) |*run| {
            if (run.state != .waiting_for_approval) continue;
            const step = run.current();
            try out.append(self.allocator, .{
                .what = if (step) |value| value.name else "approval",
                .scope = run.name,
                .key = "Ctrl+Shift+A",
            });
        }
        if (self.review.count() > 0) {
            try out.append(self.allocator, .{
                .what = "changes to review",
                .scope = "waiting",
                .key = "Ctrl+Shift+R",
            });
        }
    }

    /// Rebuild the navigator from the workspace's files, keeping whatever the
    /// reader had opened open.
    pub fn rebuildFiles(self: *App) !void {
        const entries = self.workspace.explorer.entries.items;
        const relative = try self.allocator.alloc([]const u8, entries.len);
        defer self.allocator.free(relative);
        for (entries, relative) |path, *name| name.* = self.relativePath(path);
        try self.files.rebuild(relative);
        // A navigator that opens with everything shut shows nothing, so the
        // folders at the top are open and the rest are the reader's to open.
        for (self.files.nodes.items) |node| {
            if (node.depth == 0 and node.folder) try self.files.expand(node.path);
        }
    }

    /// The navigator: folders that open and close, names that stay on one line.
    /// A row is a name, not a paragraph - a filename that wraps moves every row
    /// under it, and a navigator nobody can scan is not a navigator.
    fn drawExplorerTree(self: *App, r: *Renderer) !void {
        const bounds = self.geometry.explorer;
        r.clip = bounds;
        try r.rect(bounds, theme.panel);
        const line = r.atlas.line_height;
        const rows: usize = @intFromFloat(@max(0, bounds.h - 34) / line);
        if (self.tree_first > self.files.count()) self.tree_first = 0;
        const Painter = struct {
            r: *Renderer,
            tree: *const tree_widget.Tree,
            bounds: Rect,
            line: f32,
            first: usize,
            rows: usize,
            index: usize = 0,
            scratch: [256]u8 = undefined,

            fn visit(painter: *@This(), node: *const tree_widget.Node) anyerror!void {
                defer painter.index += 1;
                if (painter.index < painter.first) return;
                const row = painter.index - painter.first;
                if (row >= painter.rows) return;
                const y = painter.bounds.y + 34 + @as(f32, @floatFromInt(row)) * painter.line;
                const step = painter.r.atlas.advance * 2;
                const indent = @as(f32, @floatFromInt(node.depth)) * step;
                const x = painter.bounds.x + 10 + indent;
                if (node.folder) {
                    // A folder says whether it is open, which is the difference
                    // between a tree and a list.
                    const mark = if (painter.tree.isExpanded(node.path)) "▾" else "▸";
                    try painter.r.text(x, y + 4, mark, theme.accent);
                }
                const room: usize = @intFromFloat(@max(4, (painter.bounds.x + painter.bounds.w - 8 - x - step) / painter.r.atlas.advance));
                const label = wrap.elide(&painter.scratch, node.name, room);
                try painter.r.text(x + step, y + 4, label, if (node.folder) theme.text else theme.muted);
            }
        };
        var painter: Painter = .{
            .r = r,
            .tree = &self.files,
            .bounds = bounds,
            .line = line,
            .first = self.tree_first,
            .rows = rows,
        };
        try self.files.visit(&painter, Painter.visit);
    }

    /// The runs this session knows about. A run that needs a person says so
    /// rather than looking like the ones that are merely working.
    fn drawRuns(self: *App, r: *Renderer, frame: std.mem.Allocator) !void {
        const bounds = self.geometry.explorer;
        r.clip = bounds;
        try r.rect(bounds, theme.panel);
        var y = bounds.y + 36;

        var inbox: std.ArrayList(Decision) = .empty;
        defer inbox.deinit(self.allocator);
        try self.decisions(&inbox);
        if (inbox.items.len > 0) {
            try r.text(bounds.x + 12, y, "NEEDS YOU", theme.amber);
            y += 18;
            for (inbox.items) |decision| {
                if (y + 58 > bounds.y + bounds.h) break;
                var label: [160]u8 = undefined;
                const what = try std.fmt.bufPrint(&label, "{s} · {s}", .{ decision.what, decision.scope });
                // A decision says which run it is about, and wraps if it has to:
                // a truncated question is one somebody has to go looking for.
                r.clip = bounds;
                try wrapped(r, frame, .{
                    .x = bounds.x + 12,
                    .y = y,
                    .w = bounds.w - 24,
                    .h = r.atlas.line_height * 2,
                }, what, theme.text);
                try r.text(bounds.x + 12, y + r.atlas.line_height * 2, decision.key, theme.muted);
                y += r.atlas.line_height * 2 + 24;
            }
            r.clip = bounds;
            y += 8;
            try r.text(bounds.x + 12, y, "RUNS", theme.muted);
            y += 18;
        }

        for (self.runs.items, 0..) |*run, index| {
            if (y + 44 > bounds.y + bounds.h) break;
            const chosen = index == self.run_index;
            if (chosen) try r.rect(.{ .x = bounds.x + 4, .y = y - 4, .w = bounds.w - 8, .h = 44 }, theme.raised);
            r.clip = bounds;
            try wrapped(r, frame, .{
                .x = bounds.x + 12,
                .y = y,
                .w = bounds.w - 24,
                .h = r.atlas.line_height,
            }, run.name, if (chosen) theme.accent else theme.text);
            const step = run.current();
            var state: [80]u8 = undefined;
            const label = try std.fmt.bufPrint(&state, "{s} · {s}", .{
                if (step) |value| value.name else "nothing left",
                switch (run.state) {
                    .running => "running",
                    .waiting_for_approval => "waiting for you",
                    .done => "done",
                    .failed => "failed",
                },
            });
            r.clip = bounds;
            try r.text(bounds.x + 12, y + r.atlas.line_height, label, if (run.state == .waiting_for_approval) theme.amber else theme.muted);
            y += 48;
        }
        if (self.runs.items.len == 0) {
            try r.text(bounds.x + 12, bounds.y + 36, "No runs yet.", theme.muted);
        }
    }

    /// The Compose perspective: the run's steps as a sequence, with the
    /// artifact each joint carries. A pipeline reads left to right the way the
    /// pipeline does; a graph earns its keep when a workflow branches, and a
    /// strip pretending to be a graph would be worse than an honest one.
    fn drawCompose(self: *App, r: *Renderer, frame: std.mem.Allocator) !void {
        const bounds = self.geometry.editor;
        r.clip = bounds;
        try r.rect(bounds, theme.background);
        try r.text(bounds.x + 24, bounds.y + 20, "COMPOSE", theme.text);
        const run = self.activeRun() orelse {
            try r.text(bounds.x + 24, bounds.y + 46, "No run to compose. Start one from the palette.", theme.muted);
            return;
        };
        var header: [160]u8 = undefined;
        const title = try std.fmt.bufPrint(&header, "{s} · {s}", .{
            run.name,
            switch (run.state) {
                .running => "running",
                .waiting_for_approval => "waiting for you",
                .done => "done",
                .failed => "failed",
            },
        });
        try r.text(bounds.x + 108, bounds.y + 20, title, theme.accent);
        try r.text(bounds.x + 24, bounds.y + 46, "Left to right, the way it runs. Each joint carries what the step before it produced.", theme.muted);

        const count: f32 = @floatFromInt(@max(1, run.steps.len));
        const gap: f32 = 44;
        const available = bounds.w - 48 - gap * (count - 1);
        const box_w = @max(96, @min(180, available / count));
        const box_h: f32 = 88;
        var x = bounds.x + 24;
        const y = bounds.y + 96;
        for (run.steps, 0..) |step, index| {
            const chosen = index == self.compose_selected;
            try r.rect(.{ .x = x, .y = y, .w = box_w, .h = box_h }, theme.panel);
            try r.rect(.{ .x = x, .y = y, .w = 3, .h = box_h }, switch (step.state) {
                .waiting => theme.border,
                .running => theme.accent,
                .done => theme.muted,
                .failed => theme.red,
            });
            try wrapped(r, frame, .{ .x = x + 12, .y = y + 10, .w = box_w - 24, .h = r.atlas.line_height }, step.name, if (chosen) theme.accent else theme.text);
            const who = switch (step.action) {
                .agent => |agent| if (agent.harness < self.clients.len) self.clients[agent.harness].preset.name else "harness",
                .command => "command",
                .approval => "you",
            };
            try r.text(x + 12, y + 12 + r.atlas.line_height, who, theme.muted);
            const state = switch (step.state) {
                .waiting => "○ waiting",
                .running => "● running",
                .done => "✓ done",
                .failed => "✗ failed",
            };
            try r.text(x + 12, y + box_h - 24, state, switch (step.state) {
                .waiting => theme.muted,
                .running => theme.accent,
                .done => theme.text,
                .failed => theme.red,
            });
            x += box_w;
            if (index + 1 < run.steps.len) {
                // The joint, and what travels over it: a pipe that says what it
                // carries is the whole idea, and one that does not is decoration.
                try r.text(x + 16, y + box_h / 2 - 8, "│", theme.accent);
                const carries = run.steps[index + 1].produces.label();
                try r.text(x + gap / 2 - r.atlas.advance * 2, y + box_h + 8, carries, theme.muted);
                x += gap;
            }
        }
    }

    /// The review surface: what is waiting to be accepted, and what stands in
    /// the way of accepting it. A change that cannot land is shown as such
    /// rather than hidden, because the developer is being asked about it.
    fn drawReview(self: *App, r: *Renderer, frame: std.mem.Allocator) !void {
        _ = frame;
        const bounds = self.geometry.editor;
        r.clip = bounds;
        try r.rect(bounds, theme.background);
        const queue = &self.review;
        var header: [160]u8 = undefined;
        const link = if (self.activeRun()) |run| run.name else "no run";
        const title = try std.fmt.bufPrint(&header, "REVIEW · {d} change(s) · {s}", .{ queue.count(), link });
        try r.text(bounds.x + 24, bounds.y + 20, title, theme.text);
        try r.text(bounds.x + 24, bounds.y + 44, "Up/Down choose · A accept · R reject · Esc back to the code", theme.muted);
        if (queue.count() == 0) {
            try r.text(bounds.x + 24, bounds.y + 84, "Nothing is waiting for you.", theme.muted);
            return;
        }
        if (self.review_selected >= queue.count()) self.review_selected = queue.count() - 1;
        var y = bounds.y + 84;
        for (0..queue.count()) |index| {
            if (y + 52 > bounds.y + bounds.h) break;
            const edit = queue.editAt(index);
            const selected = index == self.review_selected;
            if (selected) try r.rect(.{ .x = bounds.x + 8, .y = y - 4, .w = bounds.w - 16, .h = 48 }, theme.raised);
            try r.text(bounds.x + 24, y, edit.path, if (selected) theme.accent else theme.text);
            var range: [48]u8 = undefined;
            const where = try std.fmt.bufPrint(&range, "{d}..{d}", .{ edit.start_byte, edit.end_byte });
            try r.text(bounds.x + bounds.w - 160, y, where, theme.muted);
            // The first line of the replacement is what the developer is
            // judging, and what is standing in the way of accepting it.
            var line: usize = 0;
            while (line < edit.replacement.len and edit.replacement[line] != '\n') : (line += 1) {}
            try r.text(bounds.x + 44, y + 22, edit.replacement[0..line], theme.text);
            const obstacle = self.reviewObstacle(index);
            try r.text(bounds.x + bounds.w - 320, y + 22, obstacle orelse "ready to apply", if (obstacle != null) theme.amber else theme.accent);
            y += 56;
        }
    }

    /// Accept the selected change, or say why it could not be accepted.
    pub fn acceptReview(self: *App) !void {
        const queue = &self.review;
        if (queue.count() == 0) return error.NothingToReview;
        if (self.review_selected >= queue.count()) self.review_selected = queue.count() - 1;
        const outcome = try self.workspace.applyReview(queue, self.review_selected);
        switch (outcome) {
            .applied => {
                if (self.review_selected >= queue.count() and self.review_selected > 0) self.review_selected -= 1;
                self.status("Review: change applied.", .{});
            },
            .conflict => self.status("Review: the file changed since this was proposed.", .{}),
            .invalid => self.status("Review: that change does not fit the file.", .{}),
        }
    }

    /// Reject the selected change.
    pub fn rejectReview(self: *App) void {
        const queue = &self.review;
        if (queue.count() == 0) return;
        if (self.review_selected >= queue.count()) self.review_selected = queue.count() - 1;
        queue.discard(self.review_selected);
        if (self.review_selected >= queue.count() and self.review_selected > 0) self.review_selected -= 1;
        self.status("Review: change rejected.", .{});
    }

    pub fn runWaiting(self: *App) bool {
        const run = self.activeRun() orelse return false;
        return run.state == .waiting_for_approval;
    }

    /// Approve the step the run is waiting on. The decision is an artifact like
    /// any other: the run records that a person accepted what came before it,
    /// which is what separates a workflow's progress from its acceptance.
    pub fn approveStep(self: *App) !void {
        const run = self.activeRun() orelse return error.NoRun;
        const step = run.current() orelse return error.RunFinished;
        if (step.action != .approval) return error.NotAnApproval;
        var body: [256]u8 = undefined;
        const words = try std.fmt.bufPrint(&body, "approved by the developer; {d} artifact(s) preceded it", .{run.artifacts.items.len});
        try run.record(step, words);
        // Approving the last step finishes the run: an approval that leaves a
        // finished run looking busy is a run nobody can trust the state of.
        run.state = if (run.isDone()) .done else .running;
        self.status("Run {s}: {s} approved.", .{ run.name, step.name });
    }

    /// The signature action: send what the composer holds, with the context
    /// the inspector shows, to one harness. Choosing the destination is the
    /// whole gesture; the interface names it before anything is sent.
    pub fn pipeTo(self: *App, index: usize) !void {
        if (index >= self.clients.len) return error.NoSuchAgent;
        self.active = index;
        self.transcript_scroll = 0;
        try self.submit(false);
    }

    fn drawInspector(self: *App, r: *Renderer, frame: std.mem.Allocator) !void {
        const bounds = self.geometry.agents;
        r.clip = bounds;
        try r.rect(bounds, theme.panel);
        try r.rect(.{ .x = bounds.x, .y = bounds.y, .w = 1, .h = bounds.h }, theme.border);
        try r.text(bounds.x + 14, bounds.y + 13, "INSPECTOR", theme.text);

        // What the inspector is about: the buffer the caret is in, and where.
        // The name comes from the same place the tab strip gets it, because two
        // names for one buffer is how an inspector ends up saying "no file"
        // about the file that is on screen.
        const path = self.workspace.bufferName(self.workspace.activeIndex());
        var subject: [128]u8 = undefined;
        const line = self.workspace.activeDocument().lineOf(self.workspace.activeDocument().cursor) + 1;
        const label = try std.fmt.bufPrint(&subject, "{s} · line {d}", .{ path, line });
        try r.text(bounds.x + 14, bounds.y + 31, label, theme.accent);
        if (self.runWaiting()) {
            try r.text(bounds.x + bounds.w - 108, bounds.y + 31, "1 decision", theme.amber);
        }

        const rows = [_][]const u8{ "Selection", "Current file", "Terminal output" };
        const context_y = bounds.y + 46;
        for (rows, 0..) |name, index| {
            const y = context_y + @as(f32, @floatFromInt(index)) * inspectorRowHeight(r.atlas.line_height);
            const on = self.inspector_context[index];
            try r.text(bounds.x + 12, y + 4, if (on) "[x]" else "[ ]", if (on) theme.accent else theme.muted);
            try r.text(bounds.x + 56, y + 4, name, if (on) theme.text else theme.muted);
            // What a row would carry goes under it and wraps: a second column
            // collides with the first at the narrow end of the dock, which is
            // where an inspector is most often read.
            const detail = self.inspectorDetail(index);
            try wrapped(r, frame, .{
                .x = bounds.x + 56,
                .y = y + 4 + r.atlas.line_height,
                .w = bounds.w - 70,
                .h = r.atlas.line_height * 2,
            }, detail, theme.muted);
        }

        // Wrapped text sets its own clip, so each section starts by taking the
        // dock's back: a label drawn under the last row's rect is a label that
        // gets cut in half.
        r.clip = bounds;
        const pipe_y = context_y + 3 * inspectorRowHeight(r.atlas.line_height) + 20;
        try r.text(bounds.x + 14, pipe_y - 18, "PIPE TO", theme.muted);
        for (self.clients, 0..) |client, index| {
            const y = pipe_y + @as(f32, @floatFromInt(index)) * 26;
            const chosen = index == self.active;
            const up = client.state.up();
            if (chosen) try r.rect(.{ .x = bounds.x + 6, .y = y - 1, .w = 3, .h = 20 }, theme.accent);
            var name: [96]u8 = undefined;
            const named = try std.fmt.bufPrint(&name, "{d}  {s}", .{ index + 1, client.preset.name });
            try r.text(bounds.x + 14, y + 6, named, if (up) theme.text else theme.muted);
            try r.text(bounds.x + bounds.w - 78, y + 6, client.state.label(), switch (client.state) {
                .ready => theme.accent,
                .busy, .cancelling, .initialize, .new_session => theme.amber,
                .offline, .failed => theme.muted,
            });
        }

        // The run is evidence, not the navigation: it gets the room that is
        // left after the context, the destinations, and the composer.
        const run_y = pipe_y + @as(f32, @floatFromInt(self.clients.len)) * 26 + 26;
        const client = &self.clients[self.active];
        const permission = if (client.permission != null) self.permissionRect() else null;
        const run_bottom = if (permission) |rect| rect.y - 8 else bounds.y + bounds.h - 110;
        r.clip = bounds;
        try r.text(bounds.x + 14, run_y, "RUN", theme.muted);
        // A run shows its steps first: the question a run answers is which step
        // is holding it, and the transcript is the evidence underneath.
        var steps_height: f32 = 0;
        if (self.activeRun()) |active| {
            for (active.steps, 0..) |*step, index| {
                const y = run_y + 18 + @as(f32, @floatFromInt(index)) * 22;
                if (y + 18 > run_bottom) break;
                const mark = switch (step.state) {
                    .waiting => "○",
                    .running => "●",
                    .done => "✓",
                    .failed => "✗",
                };
                const colour = switch (step.state) {
                    .waiting => theme.muted,
                    .running => theme.accent,
                    .done => theme.text,
                    .failed => theme.red,
                };
                try r.text(bounds.x + 14, y, mark, colour);
                try r.text(bounds.x + 34, y, step.name, colour);
                // The name can be a command, so what the step produces has its
                // own column rather than whatever the name left behind.
                try r.text(bounds.x + 200, y, step.produces.label(), theme.muted);
            }
            steps_height = @min(@as(f32, @floatFromInt(active.steps.len)) * 22 + 10, @max(0, run_bottom - run_y - 18));
        }
        r.clip = bounds;
        const run: Rect = .{ .x = bounds.x + 14, .y = run_y + 18 + steps_height, .w = bounds.w - 28, .h = @max(0, run_bottom - run_y - 18 - steps_height) };
        if (client.transcript.items.len == 0 and try self.drawPanel(r, frame, "transcript", run)) {
            // A registered panel owns this space, so the interface does not
            // carry a copy of what an extension would say.
        } else {
            const bytes = if (client.transcript.items.len == 0) default_help else client.transcript.items;
            try wrappedTail(r, frame, run, bytes, self.transcript_scroll, theme.text);
        }

        r.clip = bounds;
        if (permission) |rect| {
            try r.rect(rect, theme.raised);
            try r.rect(.{ .x = rect.x, .y = rect.y, .w = 3, .h = rect.h }, theme.amber);
            r.clip = rect.inset(8);
            try r.text(rect.x + 10, rect.y + 6, client.permissionTitle(), theme.amber);
            try r.text(rect.x + 10, rect.y + 38, "Alt+Y allow once", theme.accent);
            try r.text(rect.x + rect.w / 2, rect.y + 38, "Alt+N reject", theme.red);
        }

        r.clip = bounds;
        const prompt_box: Rect = .{ .x = bounds.x + 10, .y = bounds.y + bounds.h - 102, .w = bounds.w - 20, .h = 66 };
        try r.rect(prompt_box, if (self.focus == .prompt) theme.raised else theme.background);
        if (self.focus == .prompt) try r.rect(.{ .x = prompt_box.x, .y = prompt_box.y, .w = 2, .h = prompt_box.h }, theme.accent);
        // The composer names its destination: a draft is never sent somewhere
        // the interface did not say.
        var placeholder: [96]u8 = undefined;
        const empty = try std.fmt.bufPrint(&placeholder, "Ask {s}…", .{client.preset.name});
        try wrappedTail(r, frame, prompt_box.inset(8), if (self.prompt_text.items.len == 0) empty else self.prompt_text.items, 0, if (self.prompt_text.items.len == 0) theme.muted else theme.text);
        r.clip = bounds;
        // The hint is a line, not a paragraph: cut to the width it has, like
        // every other row in this panel.
        var hint: [128]u8 = undefined;
        const room: usize = @intFromFloat(@max(4, (bounds.w - 28) / r.atlas.advance));
        try r.text(bounds.x + 14, bounds.y + bounds.h - 27, wrap.elide(&hint, "click to attach · click a name to pipe", room), theme.muted);
    }

    /// A short, honest description of what a context row would carry. The
    /// numbers are the point: a row that says nothing is a row that sends
    /// nothing surprising.
    fn inspectorDetail(self: *App, index: usize) []const u8 {
        switch (index) {
            0 => {
                const range = self.selectedRange() orelse return "nothing selected";
                const document = self.workspace.activeDocument();
                const first = document.lineOf(range.start) + 1;
                const last = document.lineOf(range.end) + 1;
                return std.fmt.bufPrint(&self.inspector_scratch[0], "{s} · lines {d}-{d}", .{
                    self.workspace.bufferName(self.workspace.activeIndex()), first, last,
                }) catch "selection";
            },
            1 => {
                const lines = self.workspace.activeDocument().lineCount();
                return std.fmt.bufPrint(&self.inspector_scratch[1], "{d} lines", .{lines}) catch "file";
            },
            else => {
                const terminal = self.activeTerminal() orelse return "no terminal";
                _ = terminal;
                return "last command";
            },
        }
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

/// Text drawn from the top of a rect, wrapping at its width.
fn wrapped(r: *Renderer, frame: std.mem.Allocator, rect: Rect, bytes: []const u8, color: theme.Color) !void {
    if (rect.h < r.atlas.line_height or rect.w <= 0) return;
    // Text is clipped to the rect it is drawn in, and the clip is put back
    // afterwards: a caller that draws the next line itself has no way to know
    // this one moved the boundary.
    const outer = r.clip;
    defer r.clip = outer;
    r.clip = rect;
    const columns: usize = @intFromFloat(@max(1, rect.w / r.atlas.advance));
    var spans: std.ArrayList([]const u8) = .empty;
    try wrap.spans(frame, bytes, columns, &spans);
    const rows: usize = @intFromFloat(rect.h / r.atlas.line_height);
    for (spans.items[0..@min(spans.items.len, rows)], 0..) |span, row| {
        try r.text(rect.x, rect.y + @as(f32, @floatFromInt(row)) * r.atlas.line_height, span, color);
    }
}

fn wrappedTail(r: *Renderer, frame: std.mem.Allocator, rect: Rect, bytes: []const u8, scroll: usize, color: theme.Color) !void {
    if (rect.h < r.atlas.line_height or rect.w <= 0) return;
    const outer = r.clip;
    defer r.clip = outer;
    r.clip = rect;
    const columns: usize = @intFromFloat(@max(1, rect.w / r.atlas.advance));
    const rows: usize = @intFromFloat(rect.h / r.atlas.line_height);
    var spans: std.ArrayList([]const u8) = .empty;
    try wrap.spans(frame, bytes, columns, &spans);
    const end = spans.items.len -| @min(scroll, spans.items.len -| 1);
    const begin = end -| rows;
    for (spans.items[begin..end], 0..) |span, row| try r.text(rect.x, rect.y + @as(f32, @floatFromInt(row)) * r.atlas.line_height, span, color);
}
