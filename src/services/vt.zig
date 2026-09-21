const std = @import("std");
const g = @import("ghostty");
const Allocator = std.mem.Allocator;

/// A terminal: libghostty-vt's emulator state, the render state a surface draws
/// from, and the encoder that turns input into the bytes a program expects.
///
/// The library is C and is built by the Zig release Ghostty pins (see
/// tools/bootstrap.py). Nothing here allocates through the library except
/// through its default allocator, which is what the library's own examples do.
pub const Terminal = struct {
    allocator: Allocator,
    handle: g.GhosttyTerminal,
    render: g.GhosttyRenderState,
    row_iterator: g.GhosttyRenderStateRowIterator = null,
    row_cells: g.GhosttyRenderStateRowCells = null,
    cell_style: g.GhosttyStyle = undefined,
    colors_cache: g.GhosttyRenderStateColors = undefined,
    /// Per-cell storage: the render call fills a buffer per cell, so each cell
    /// must keep its own rather than borrowing one the next cell overwrites.
    grapheme_storage: [max_cells][max_graphemes]u32 = undefined,
    cell_storage: [max_cells]Cell = undefined,
    /// Raw cell values, one per column of the row being visited. The library
    /// hands these back by value into storage the caller owns.
    raw_storage: [max_cells]g.GhosttyCell = undefined,

    /// Scratch for the one library call that rewrites its input.
    paste_scratch: std.ArrayList(u8) = .empty,
    key_encoder: g.GhosttyKeyEncoder = null,
    key_event: g.GhosttyKeyEvent = null,
    mouse_encoder: g.GhosttyMouseEncoder = null,
    cell_width: u32 = 1,
    cell_height: u32 = 1,

    /// What a surface needs to know about a frame before it draws.
    pub const Dirty = enum { clean, partial, full };

    /// One cell of the grid, as the renderer wants it.
    /// What a cell is part of, as the shell marked it. A shell that reports its
    /// own command boundaries with OSC 133 turns a screen of text into a list
    /// of prompts, commands, and results; one that does not leaves every cell
    /// ordinary output, which is why nothing here guesses.
    pub const Semantic = enum { output, input, prompt };

    pub const Cell = struct {
        /// The grapheme's codepoints. Empty means the cell drew nothing.
        codepoints: []const u32,
        style: g.GhosttyStyle,
        semantic: Semantic = .output,
    };

    /// The last command on screen and what it printed, taken from the cells the
    /// shell marked rather than from a guess about where a prompt ends.
    pub const CommandResult = struct {
        command: []u8,
        output: []u8,

        pub fn deinit(self: *CommandResult, a: Allocator) void {
            a.free(self.command);
            a.free(self.output);
            self.* = undefined;
        }
    };

    pub const Cursor = struct {
        x: u16,
        y: u16,
        visible: bool,
        style: g.GhosttyRenderStateCursorVisualStyle,
    };

    pub const Colors = struct {
        background: g.GhosttyColorRgb,
        foreground: g.GhosttyColorRgb,
        palette: [256]g.GhosttyColorRgb,
    };

    pub fn init(a: Allocator, initial_cols: u16, initial_rows: u16) !Terminal {
        var handle: g.GhosttyTerminal = null;
        try check(g.ghostty_terminal_new(null, &handle, initial_cols, initial_rows));
        errdefer g.ghostty_terminal_free(handle);
        var render: g.GhosttyRenderState = null;
        try check(g.ghostty_render_state_new(null, &render));
        errdefer g.ghostty_render_state_free(render);
        var iterator: g.GhosttyRenderStateRowIterator = null;
        try check(g.ghostty_render_state_row_iterator_new(null, &iterator));
        errdefer g.ghostty_render_state_row_iterator_free(iterator);
        var cells: g.GhosttyRenderStateRowCells = null;
        try check(g.ghostty_render_state_row_cells_new(null, &cells));
        return .{ .allocator = a, .handle = handle, .render = render, .row_iterator = iterator, .row_cells = cells };
    }

    pub fn deinit(self: *Terminal) void {
        if (self.key_event != null) g.ghostty_key_event_free(self.key_event);
        if (self.key_encoder != null) g.ghostty_key_encoder_free(self.key_encoder);
        if (self.mouse_encoder != null) g.ghostty_mouse_encoder_free(self.mouse_encoder);
        g.ghostty_render_state_row_cells_free(self.row_cells);
        g.ghostty_render_state_row_iterator_free(self.row_iterator);
        g.ghostty_render_state_free(self.render);
        g.ghostty_terminal_free(self.handle);
        self.paste_scratch.deinit(self.allocator);
        self.* = undefined;
    }

    /// Feed bytes as they arrive from the program on the other end.
    pub fn write(self: *Terminal, bytes: []const u8) void {
        g.ghostty_terminal_vt_write(self.handle, bytes.ptr, bytes.len);
    }

    /// Tell the terminal how large it is, in cells and in pixels: the pixel
    /// size is what lets it reflow and report its own dimensions.
    pub fn resize(self: *Terminal, new_cols: u16, new_rows: u16, cell_width: u32, cell_height: u32) !void {
        try check(g.ghostty_terminal_resize(self.handle, new_cols, new_rows, cell_width, cell_height));
        self.cell_width = cell_width;
        self.cell_height = cell_height;
    }

    /// Take a snapshot for the surface to draw. Cheap when nothing changed.
    pub fn update(self: *Terminal) !void {
        try check(g.ghostty_render_state_update(self.render, self.handle));
    }

    pub fn dirty(self: *Terminal) Dirty {
        var value: g.GhosttyRenderStateDirty = g.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = g.ghostty_render_state_get(self.render, g.GHOSTTY_RENDER_STATE_DATA_DIRTY, @ptrCast(&value));
        return switch (value) {
            g.GHOSTTY_RENDER_STATE_DIRTY_PARTIAL => .partial,
            g.GHOSTTY_RENDER_STATE_DIRTY_FULL => .full,
            else => .clean,
        };
    }

    /// Clear the dirty flags once a frame has been drawn from them.
    pub fn markDrawn(self: *Terminal) void {
        const clean: g.GhosttyRenderStateDirty = g.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = g.ghostty_render_state_set(self.render, g.GHOSTTY_RENDER_STATE_OPTION_DIRTY, @ptrCast(&clean));
    }

    /// The emulator's defaults. The struct is sized: the size field is what
    /// tells the library which of its fields this build understands, so
    /// leaving it zero makes the call fail and every color come back black.
    pub fn colors(self: *Terminal) !Colors {
        var out = std.mem.zeroInit(g.GhosttyRenderStateColors, .{});
        out.size = @sizeOf(g.GhosttyRenderStateColors);
        try check(g.ghostty_render_state_colors_get(self.render, @ptrCast(&out)));
        self.colors_cache = out;
        var palette: [256]g.GhosttyColorRgb = undefined;
        for (&palette, 0..) |*entry, index| entry.* = out.palette[index];
        return .{ .background = out.background, .foreground = out.foreground, .palette = palette };
    }

    pub fn cursor(self: *Terminal) Cursor {
        var visible = false;
        _ = g.ghostty_render_state_get(self.render, g.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, @ptrCast(&visible));
        var in_viewport = false;
        _ = g.ghostty_render_state_get(self.render, g.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, @ptrCast(&in_viewport));
        var x: u16 = 0;
        var y: u16 = 0;
        var style: g.GhosttyRenderStateCursorVisualStyle = g.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
        if (visible and in_viewport) {
            _ = g.ghostty_render_state_get(self.render, g.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, @ptrCast(&x));
            _ = g.ghostty_render_state_get(self.render, g.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, @ptrCast(&y));
            _ = g.ghostty_render_state_get(self.render, g.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, @ptrCast(&style));
        }
        return .{ .x = x, .y = y, .visible = visible and in_viewport, .style = style };
    }

    /// The number of columns and rows the terminal is sized for.
    pub fn cols(self: *Terminal) u16 {
        var value: u16 = 0;
        _ = g.ghostty_terminal_get(self.handle, g.GHOSTTY_TERMINAL_DATA_COLS, @ptrCast(&value));
        return value;
    }

    pub fn rows(self: *Terminal) u16 {
        var value: u16 = 0;
        _ = g.ghostty_terminal_get(self.handle, g.GHOSTTY_TERMINAL_DATA_ROWS, @ptrCast(&value));
        return value;
    }

    /// Walk the visible rows and their cells. The visitor sees one row at a
    /// time; the cell slice is only valid during the call.
    pub fn visitRows(self: *Terminal, context: anytype, comptime visit: fn (@TypeOf(context), u16, []const Cell) anyerror!void) !void {
        try check(g.ghostty_render_state_get(self.render, g.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.row_iterator)));
        var row_index: u16 = 0;
        while (g.ghostty_render_state_row_iterator_next(self.row_iterator)) {
            try check(g.ghostty_render_state_row_get(self.row_iterator, g.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.row_cells)));
            var count: usize = 0;
            while (g.ghostty_render_state_row_cells_next(self.row_cells)) {
                if (count == max_cells) break;
                // The raw cell carries what the shell said about this cell, and
                // it is a different question from what the cell looks like.
                var raw: g.GhosttyCell = self.raw_storage[count];
                var semantic: g.GhosttyCellSemanticContent = @intCast(g.GHOSTTY_CELL_SEMANTIC_OUTPUT);
                if (g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw)) == g.GHOSTTY_SUCCESS) {
                    _ = g.ghostty_cell_get(raw, g.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, @ptrCast(&semantic));
                }
                var grapheme_len: u32 = 0;
                _ = g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&grapheme_len));
                // Sized structs again: the style is read through one, so the
                // size must be set before the library will fill any of it.
                var style = std.mem.zeroInit(g.GhosttyStyle, .{});
                style.size = @sizeOf(g.GhosttyStyle);
                const got_style = g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, @ptrCast(&style));
                if (got_style != g.GHOSTTY_SUCCESS) style = std.mem.zeroInit(g.GhosttyStyle, .{});
                if (grapheme_len != 0) {
                    const take = @min(grapheme_len, max_graphemes);
                    _ = g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, @ptrCast(&self.grapheme_storage[count]));
                    self.cell_storage[count] = .{
                        .codepoints = self.grapheme_storage[count][0..take],
                        .style = style,
                        .semantic = semanticOf(semantic),
                    };
                } else {
                    self.cell_storage[count] = .{ .codepoints = &.{}, .style = style, .semantic = semanticOf(semantic) };
                }
                count += 1;
            }
            try visit(context, row_index, self.cell_storage[0..count]);
            row_index += 1;
        }
    }

    // ---- input ------------------------------------------------------------

    pub const Modifiers = struct {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        super: bool = false,

        fn toC(self: Modifiers) g.GhosttyMods {
            var mods: g.GhosttyMods = 0;
            if (self.shift) mods |= @intCast(g.GHOSTTY_MODS_SHIFT);
            if (self.ctrl) mods |= @intCast(g.GHOSTTY_MODS_CTRL);
            if (self.alt) mods |= @intCast(g.GHOSTTY_MODS_ALT);
            if (self.super) mods |= @intCast(g.GHOSTTY_MODS_SUPER);
            return mods;
        }
    };

    pub const KeyAction = enum { press, release, repeat };

    /// Encode one key event the way the program expects to receive it.
    ///
    /// `text` is what the keystroke produced, if anything: a letter carries
    /// itself, a control key carries none and the encoder derives its control
    /// byte instead. The encoder is refreshed from the terminal first, because
    /// an application that enabled the Kitty protocol or application cursor
    /// keys changes the bytes it wants; `unshifted` is the codepoint without
    /// modifiers, which that protocol reports.
    pub fn encodeKey(
        self: *Terminal,
        key: g.GhosttyKey,
        action: KeyAction,
        mods: Modifiers,
        text: []const u8,
        unshifted: ?u21,
        out: []u8,
    ) ![]u8 {
        try self.syncEncoders();
        if (self.key_event == null) try check(g.ghostty_key_event_new(null, &self.key_event));
        _ = g.ghostty_key_event_set_key(self.key_event, key);
        _ = g.ghostty_key_event_set_action(self.key_event, switch (action) {
            .press => g.GHOSTTY_KEY_ACTION_PRESS,
            .release => g.GHOSTTY_KEY_ACTION_RELEASE,
            .repeat => g.GHOSTTY_KEY_ACTION_REPEAT,
        });
        _ = g.ghostty_key_event_set_mods(self.key_event, mods.toC());
        g.ghostty_key_event_set_utf8(self.key_event, if (text.len == 0) null else text.ptr, text.len);
        if (unshifted) |codepoint| _ = g.ghostty_key_event_set_unshifted_codepoint(self.key_event, codepoint);
        var written: usize = 0;
        const result = g.ghostty_key_encoder_encode(self.key_encoder, self.key_event, out.ptr, out.len, &written);
        if (result == g.GHOSTTY_OUT_OF_SPACE) return error.EncodeTooLong;
        try check(result);
        return out[0..written];
    }

    pub const MouseAction = enum { press, release, motion };
    pub const MouseButton = enum { left, middle, right, four, five, six, seven, eight, nine, ten, eleven, none };

    /// Encode a mouse event at a cell position, or nothing when the program has
    /// not asked for mouse reporting: a terminal that reports clicks nobody
    /// wanted types into the shell instead of moving the cursor. The encoder
    /// places reports in pixels, so the cell size converts here and the caller
    /// works in the coordinates the grid already uses.
    pub fn encodeMouse(
        self: *Terminal,
        action: MouseAction,
        button: MouseButton,
        cell_x: u16,
        cell_y: u16,
        mods: Modifiers,
        out: []u8,
    ) ![]u8 {
        if (self.mouseTracking() == @as(g.GhosttyMouseTrackingMode, @intCast(g.GHOSTTY_MOUSE_TRACKING_NONE))) return out[0..0];
        try self.syncEncoders();
        var event: g.GhosttyMouseEvent = null;
        try check(g.ghostty_mouse_event_new(null, &event));
        defer g.ghostty_mouse_event_free(event);
        g.ghostty_mouse_event_set_action(event, switch (action) {
            .press => @intCast(g.GHOSTTY_MOUSE_ACTION_PRESS),
            .release => @intCast(g.GHOSTTY_MOUSE_ACTION_RELEASE),
            .motion => @intCast(g.GHOSTTY_MOUSE_ACTION_MOTION),
        });
        g.ghostty_mouse_event_set_button(event, switch (button) {
            .left => @intCast(g.GHOSTTY_MOUSE_BUTTON_LEFT),
            .middle => @intCast(g.GHOSTTY_MOUSE_BUTTON_MIDDLE),
            .right => @intCast(g.GHOSTTY_MOUSE_BUTTON_RIGHT),
            .four => @intCast(g.GHOSTTY_MOUSE_BUTTON_FOUR),
            .five => @intCast(g.GHOSTTY_MOUSE_BUTTON_FIVE),
            .six => @intCast(g.GHOSTTY_MOUSE_BUTTON_SIX),
            .seven => @intCast(g.GHOSTTY_MOUSE_BUTTON_SEVEN),
            .eight => @intCast(g.GHOSTTY_MOUSE_BUTTON_EIGHT),
            .nine => @intCast(g.GHOSTTY_MOUSE_BUTTON_NINE),
            .ten => @intCast(g.GHOSTTY_MOUSE_BUTTON_TEN),
            .eleven => @intCast(g.GHOSTTY_MOUSE_BUTTON_ELEVEN),
            .none => @intCast(g.GHOSTTY_MOUSE_BUTTON_UNKNOWN),
        });
        g.ghostty_mouse_event_set_mods(event, mods.toC());
        const width: f32 = @floatFromInt(self.cell_width);
        const height: f32 = @floatFromInt(self.cell_height);
        g.ghostty_mouse_event_set_position(event, .{
            .x = (@as(f32, @floatFromInt(cell_x)) + 0.5) * width,
            .y = (@as(f32, @floatFromInt(cell_y)) + 0.5) * height,
        });
        var written: usize = 0;
        const result = g.ghostty_mouse_encoder_encode(self.mouse_encoder, event, out.ptr, out.len, &written);
        if (result == g.GHOSTTY_OUT_OF_SPACE) return error.EncodeTooLong;
        try check(result);
        return out[0..written];
    }

    /// Report that the terminal gained or lost focus, for programs that asked.
    pub fn encodeFocus(self: *Terminal, gained: bool, out: []u8) ![]u8 {
        if (!self.mode(modeFocusEvent())) return out[0..0];
        var written: usize = 0;
        const result = g.ghostty_focus_encode(
            if (gained) g.GHOSTTY_FOCUS_GAINED else g.GHOSTTY_FOCUS_LOST,
            out.ptr,
            out.len,
            &written,
        );
        if (result == g.GHOSTTY_OUT_OF_SPACE) return error.EncodeTooLong;
        try check(result);
        return out[0..written];
    }

    /// Wrap pasted text: bracketed when the program asked, with unsafe control
    /// bytes stripped either way.
    ///
    /// The library strips those bytes by writing over the input, so it works on
    /// a copy here: a caller's slice may be a literal, which is not writable.
    pub fn encodePaste(self: *Terminal, text: []const u8, out: []u8) ![]u8 {
        self.paste_scratch.clearRetainingCapacity();
        try self.paste_scratch.appendSlice(self.allocator, text);
        var written: usize = 0;
        const result = g.ghostty_paste_encode(
            self.paste_scratch.items.ptr,
            text.len,
            self.mode(modeBracketedPaste()),
            out.ptr,
            out.len,
            &written,
        );
        if (result == g.GHOSTTY_OUT_OF_SPACE) return error.EncodeTooLong;
        try check(result);
        return out[0..written];
    }

    /// Ask the terminal for one mode, such as bracketed paste or focus events.
    pub fn mode(self: *Terminal, which: g.GhosttyMode) bool {
        var query = g.GhosttyTerminalModeConfig{ .mode = which, .value = false };
        _ = g.ghostty_terminal_get(self.handle, g.GHOSTTY_TERMINAL_DATA_MODE, @ptrCast(&query));
        return query.value;
    }

    /// The last command the shell marked, and what it printed. Null when the
    /// shell has not marked anything: text that merely looks like a prompt is
    /// not a command, and the difference is the whole point of the markers.
    pub fn lastCommand(self: *Terminal, a: Allocator) !?CommandResult {
        const Collector = struct {
            list: Allocator,
            /// Every row is written out at full width so a row's text can be
            /// taken by its number, and so a command keeps the columns it was
            /// typed in.
            width: usize,
            /// One entry per row: was any cell part of a command, and was any
            /// part of its output?
            commands: std.ArrayList(u16) = .empty,
            results: std.ArrayList(u16) = .empty,
            text: std.ArrayList(u8) = .empty,

            fn visit(collector: *@This(), row: u16, cells: []const Cell) anyerror!void {
                var is_command = false;
                var is_result = false;
                var wrote = false;
                var column: usize = collector.width;
                for (cells) |cell| {
                    if (column == 0) break;
                    switch (cell.semantic) {
                        .input => is_command = true,
                        .output => is_result = true,
                        .prompt => {},
                    }
                    const byte: u8 = if (cell.codepoints.len == 0 or cell.codepoints[0] > 0x7f)
                        ' '
                    else
                        @intCast(cell.codepoints[0]);
                    try collector.text.append(collector.list, byte);
                    column -= 1;
                    if (cell.codepoints.len != 0) wrote = true;
                }
                while (column > 0) : (column -= 1) try collector.text.append(collector.list, ' ');
                if (is_command) try collector.commands.append(collector.list, row);
                // A row that is part of a command is not part of its output,
                // however the shell tagged the rest of the line.
                if (is_result and !is_command and wrote) try collector.results.append(collector.list, row);
            }
        };
        var collector: Collector = .{ .list = a, .width = self.cols() };
        defer collector.commands.deinit(a);
        defer collector.results.deinit(a);
        defer collector.text.deinit(a);
        try self.visitRows(&collector, Collector.visit);
        if (collector.commands.items.len == 0) return null;
        // The last command on screen, and the output that followed it: anything
        // before it belongs to a command that already ran.
        const last = collector.commands.items[collector.commands.items.len - 1];
        var command: std.ArrayList(u8) = .empty;
        errdefer command.deinit(a);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(a);
        // A command long enough to wrap occupies consecutive rows, so the whole
        // of it is the run of them that ends at the last one: anything earlier
        // belongs to a command that already ran.
        const width = self.cols();
        var first = last;
        while (first > 0) {
            var contiguous = false;
            for (collector.commands.items) |row| {
                if (row == first - 1) contiguous = true;
            }
            if (!contiguous) break;
            first -= 1;
        }
        for (collector.commands.items) |row| {
            if (row < first or row > last) continue;
            try command.appendSlice(a, collector.text.items[@as(usize, row) * width ..][0..width]);
        }
        for (collector.results.items) |row| {
            if (row <= last) continue;
            try output.appendSlice(a, collector.text.items[@as(usize, row) * width ..][0..width]);
            try output.append(a, '\n');
        }
        return .{ .command = try command.toOwnedSlice(a), .output = try output.toOwnedSlice(a) };
    }

    /// A place on the screen, in cells from the top left.
    pub const Point = struct { x: u16, y: u16 };

    /// The text a selection covers.
    ///
    /// A terminal's rows are padded to the screen's width, so each row is cut
    /// where its content ends: copying a line should not paste a screenful of
    /// spaces behind it. The selection is over the viewport, which is what a
    /// pointer can reach.
    pub fn select(self: *Terminal, a: Allocator, from: Point, to: Point) ![]u8 {
        // A selection is two corners, and a reader can drag either way: they are
        // put in reading order first, on both axes, so a drag upwards and to the
        // left means the same as the same drag made the other way.
        const forward = from.y < to.y or (from.y == to.y and from.x <= to.x);
        const first = if (forward) from else to;
        const last = if (forward) to else from;
        const Collector = struct {
            list: Allocator,
            from: Point,
            to: Point,
            out: std.ArrayList(u8) = .empty,
            row: u16 = 0,

            fn visit(collector: *@This(), row: u16, cells: []const Cell) anyerror!void {
                _ = row;
                if (collector.row < collector.from.y or collector.row > collector.to.y) {
                    collector.row += 1;
                    return;
                }
                defer collector.row += 1;
                const start: usize = if (collector.row == collector.from.y) collector.from.x else 0;
                const end: usize = if (collector.row == collector.to.y) collector.to.x else std.math.maxInt(u16);
                var line: [1024]u8 = undefined;
                var written: usize = 0;
                for (cells, 0..) |cell, column| {
                    if (column < start or column > end) continue;
                    if (written == line.len) break;
                    if (cell.codepoints.len == 0) {
                        line[written] = ' ';
                        written += 1;
                        continue;
                    }
                    const codepoint = std.math.cast(u21, cell.codepoints[0]) orelse continue;
                    written += std.unicode.utf8Encode(codepoint, line[written..]) catch 0;
                }
                // Cut the padding, keep the text.
                while (written > 0 and line[written - 1] == ' ') written -= 1;
                try collector.out.appendSlice(collector.list, line[0..written]);
                if (collector.row < collector.to.y) try collector.out.append(collector.list, '\n');
            }
        };
        var collector: Collector = .{ .list = a, .from = first, .to = last };
        errdefer collector.out.deinit(a);
        try self.visitRows(&collector, Collector.visit);
        return collector.out.toOwnedSlice(a);
    }

    /// Move the viewport through scrollback. Negative scrolls up into history,
    /// which is what a wheel does; the program's own screen is untouched.
    pub fn scroll(self: *Terminal, lines: isize) void {
        const request = g.GhosttyTerminalScrollViewport{
            .tag = @intCast(g.GHOSTTY_SCROLL_VIEWPORT_DELTA),
            .value = .{ .delta = lines },
        };
        g.ghostty_terminal_scroll_viewport(self.handle, request);
    }

    pub const Scrollbar = struct {
        total: u64,
        offset: u64,
        len: u64,
    };

    /// Where the viewport sits in the scrollable area. A terminal with no
    /// history reports a total equal to its height, which is a bar of nothing.
    pub fn scrollbar(self: *Terminal) !Scrollbar {
        var value = std.mem.zeroInit(g.GhosttyTerminalScrollbar, .{});
        try check(g.ghostty_terminal_get(self.handle, g.GHOSTTY_TERMINAL_DATA_SCROLLBAR, @ptrCast(&value)));
        return .{ .total = value.total, .offset = value.offset, .len = value.len };
    }

    /// Whether the program asked for mouse reporting: a wheel over a terminal
    /// running one goes to that program instead of scrolling history.
    pub fn wantsMouse(self: *Terminal) bool {
        return self.mouseTracking() != @as(g.GhosttyMouseTrackingMode, @intCast(g.GHOSTTY_MOUSE_TRACKING_NONE));
    }

    fn mouseTracking(self: *Terminal) g.GhosttyMouseTrackingMode {
        var tracking: g.GhosttyMouseTrackingMode = @intCast(g.GHOSTTY_MOUSE_TRACKING_NONE);
        _ = g.ghostty_terminal_get(self.handle, g.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, @ptrCast(&tracking));
        return tracking;
    }

    /// Refresh the encoders from the terminal's modes before encoding input.
    fn syncEncoders(self: *Terminal) !void {
        if (self.key_encoder == null) try check(g.ghostty_key_encoder_new(null, &self.key_encoder));
        _ = g.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.handle);
        if (self.mouse_encoder == null) try check(g.ghostty_mouse_encoder_new(null, &self.mouse_encoder));
        // The encoder itself knows the format and modes the application asked
        // for; whether to report at all is the tracking mode's business, which
        // the caller checks before encoding. It still needs to be told how big a
        // cell is: the size option it takes refuses zero, and an encoder without
        // it stays silent.
        var width: u32 = 0;
        var height: u32 = 0;
        _ = g.ghostty_terminal_get(self.handle, g.GHOSTTY_TERMINAL_DATA_WIDTH_PX, @ptrCast(&width));
        _ = g.ghostty_terminal_get(self.handle, g.GHOSTTY_TERMINAL_DATA_HEIGHT_PX, @ptrCast(&height));
        var size = std.mem.zeroInit(g.GhosttyMouseEncoderSize, .{});
        size.size = @sizeOf(g.GhosttyMouseEncoderSize);
        size.screen_width = width;
        size.screen_height = height;
        size.cell_width = self.cell_width;
        size.cell_height = self.cell_height;
        g.ghostty_mouse_encoder_setopt(self.mouse_encoder, @intCast(g.GHOSTTY_MOUSE_ENCODER_OPT_SIZE), @ptrCast(&size));
        g.ghostty_mouse_encoder_setopt_from_terminal(self.mouse_encoder, self.handle);
    }

    /// A grapheme longer than this is truncated; no real text reaches it.
    pub const max_graphemes = 16;
    /// A row wider than this is truncated. Terminals beyond it exist, and this
    /// bound is what the surface draws rather than an allocation per frame.
    pub const max_cells = 512;
};

/// DEC private modes that change what the editor sends. The translated header
/// carries these as expressions it cannot type, so they are built here from the
/// same numbers the C header defines.
fn modeFocusEvent() g.GhosttyMode {
    return g.ghostty_mode_new(1004, false);
}

fn modeBracketedPaste() g.GhosttyMode {
    return g.ghostty_mode_new(2004, false);
}

fn check(result: g.GhosttyResult) !void {
    if (result != g.GHOSTTY_SUCCESS) return error.GhosttyCall;
}

test "a terminal echoes what it is fed" {
    var terminal = try Terminal.init(std.testing.allocator, 20, 4);
    defer terminal.deinit();
    terminal.write("hello\r\nworld");
    try terminal.update();
    try std.testing.expectEqual(@as(u16, 20), terminal.cols());
    try std.testing.expectEqual(@as(u16, 4), terminal.rows());
    try std.testing.expect(terminal.dirty() != .clean);

    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        fn visit(self: *@This(), row: u16, cells: []const Terminal.Cell) anyerror!void {
            _ = row;
            for (cells) |cell| {
                if (cell.codepoints.len == 0) {
                    try self.text.append(std.testing.allocator, ' ');
                } else {
                    try self.text.append(std.testing.allocator, @intCast(cell.codepoints[0]));
                }
            }
            try self.text.append(std.testing.allocator, '\n');
        }
    };
    var collector: Collector = .{};
    defer collector.text.deinit(std.testing.allocator);
    try terminal.visitRows(&collector, Collector.visit);
    try std.testing.expect(std.mem.startsWith(u8, collector.text.items, "hello"));
    try std.testing.expect(std.mem.indexOf(u8, collector.text.items, "world") != null);
}

test "input is encoded the way the program asked for it" {
    var terminal = try Terminal.init(std.testing.allocator, 20, 4);
    defer terminal.deinit();
    var buffer: [128]u8 = undefined;
    // A cell size is what the input encoders need to place a mouse report.
    try terminal.resize(20, 4, 9, 22);

    // A letter carries its own text; a control key carries none.
    try std.testing.expectEqualStrings("a", try terminal.encodeKey(g.GHOSTTY_KEY_A, .press, .{}, "a", null, &buffer));
    try std.testing.expectEqualStrings("\x01", try terminal.encodeKey(g.GHOSTTY_KEY_A, .press, .{ .ctrl = true }, "", null, &buffer));
    try std.testing.expectEqualStrings("\r", try terminal.encodeKey(g.GHOSTTY_KEY_ENTER, .press, .{}, "", null, &buffer));

    // An arrow is a cursor sequence, and the application cursor mode changes
    // which one: that mode is why the encoder is refreshed from the terminal.
    try std.testing.expectEqualStrings("\x1b[A", try terminal.encodeKey(g.GHOSTTY_KEY_ARROW_UP, .press, .{}, "", null, &buffer));
    terminal.write("\x1b[?1h");
    try std.testing.expectEqualStrings("\x1bOA", try terminal.encodeKey(g.GHOSTTY_KEY_ARROW_UP, .press, .{}, "", null, &buffer));
    terminal.write("\x1b[?1l");

    // With the Kitty protocol enabled, a modified key reports its codepoint
    // instead of the legacy control byte.
    terminal.write("\x1b[>8u");
    const kitty = try terminal.encodeKey(g.GHOSTTY_KEY_A, .press, .{}, "a", 'a', &buffer);

    try std.testing.expectEqualStrings("\x1b[97u", kitty);
    terminal.write("\x1b[<u");

    // Focus events only when asked, bracketed paste only when asked.
    try std.testing.expectEqual(@as(usize, 0), (try terminal.encodeFocus(true, &buffer)).len);
    terminal.write("\x1b[?1004h");
    try std.testing.expectEqualStrings("\x1b[I", try terminal.encodeFocus(true, &buffer));
    try std.testing.expectEqualStrings("\x1b[O", try terminal.encodeFocus(false, &buffer));

    try std.testing.expectEqualStrings("hi", try terminal.encodePaste("hi", &buffer));
    terminal.write("\x1b[?2004h");
    try std.testing.expectEqualStrings("\x1b[200~hi\x1b[201~", try terminal.encodePaste("hi", &buffer));
    // A paste carrying a control byte is stripped rather than delivered.
    const unsafe = try terminal.encodePaste("a\x03b", &buffer);
    try std.testing.expect(std.mem.indexOfScalar(u8, unsafe, 0x03) == null);

    // Mouse reporting is silent until the program enables it, then speaks SGR.
    try std.testing.expectEqual(@as(usize, 0), (try terminal.encodeMouse(.press, .left, 3, 2, .{}, &buffer)).len);
    terminal.write("\x1b[?1000h\x1b[?1006h");
    const report = try terminal.encodeMouse(.press, .left, 3, 2, .{}, &buffer);

    try std.testing.expectEqualStrings("\x1b[<0;4;3M", report);
}

test "a terminal's whole lifecycle releases everything it took" {
    // The testing allocator fails the test on any leak, which is what keeps the
    // buffers a surface holds from quietly outliving the terminal.
    var terminal = try Terminal.init(std.testing.allocator, 80, 24);
    defer terminal.deinit();
    try terminal.resize(80, 24, 9, 22);
    terminal.write("\x1b[1;32mgreen\x1b[0m\r\nsecond row\r\n\x1b[4munderlined\x1b[0m");
    try terminal.update();
    try std.testing.expect(terminal.cols() == 80 and terminal.rows() == 24);
    var buffer: [128]u8 = undefined;
    _ = try terminal.encodeKey(g.GHOSTTY_KEY_A, .press, .{}, "a", null, &buffer);
    _ = try terminal.encodeFocus(true, &buffer);
    _ = try terminal.encodePaste("pasted", &buffer);
    _ = try terminal.encodeMouse(.press, .left, 1, 1, .{}, &buffer);
    const Collector = struct {
        rows: usize = 0,
        fn visit(self: *@This(), _: u16, _: []const Terminal.Cell) anyerror!void {
            self.rows += 1;
        }
    };
    var collector: Collector = .{};
    try terminal.visitRows(&collector, Collector.visit);
    try std.testing.expect(collector.rows > 0);
}

test "the viewport scrolls into history and back" {
    var terminal = try Terminal.init(std.testing.allocator, 16, 3);
    defer terminal.deinit();
    const Collector = struct {
        allocator: std.mem.Allocator,
        text: std.ArrayList(u8) = .empty,
        fn visit(self: *@This(), _: u16, cells: []const Terminal.Cell) anyerror!void {
            for (cells) |cell| {
                if (cell.codepoints.len == 0) {
                    try self.text.append(self.allocator, ' ');
                } else {
                    try self.text.append(self.allocator, @intCast(cell.codepoints[0]));
                }
            }
            try self.text.append(self.allocator, '\n');
        }
    };
    const screen = struct {
        fn read(term: *Terminal, a: std.mem.Allocator) ![]u8 {
            var collector: Collector = .{ .allocator = a };
            errdefer collector.text.deinit(a);
            try term.visitRows(&collector, Collector.visit);
            return try collector.text.toOwnedSlice(a);
        }
    }.read;

    // More lines than the screen holds, so there is history to scroll into.
    terminal.write("alpha\r\nbravo\r\ncharlie\r\ndelta\r\necho\r\n");
    try terminal.update();
    const bottom = try screen(&terminal, std.testing.allocator);
    defer std.testing.allocator.free(bottom);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "echo") != null);

    // Up two lines: earlier rows replace the newest ones.
    terminal.scroll(-2);
    try terminal.update();
    const scrolled = try screen(&terminal, std.testing.allocator);
    defer std.testing.allocator.free(scrolled);
    try std.testing.expect(std.mem.indexOf(u8, scrolled, "charlie") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled, "echo") == null);

    // And back down: the program's own screen is where it was.
    terminal.scroll(100);
    try terminal.update();
    const restored = try screen(&terminal, std.testing.allocator);
    defer std.testing.allocator.free(restored);
    try std.testing.expect(std.mem.indexOf(u8, restored, "echo") != null);
}

test "SGR attributes reach the render state" {
    var terminal = try Terminal.init(std.testing.allocator, 20, 4);
    defer terminal.deinit();
    // The screen a shell leaves behind: plain, bold, italic, and underlined on
    // consecutive rows.
    terminal.write("a\r\nb\x1b[1mB\x1b[0m\r\nc\x1b[3mC\x1b[0m\r\nd\x1b[4mD\x1b[0m");
    try terminal.update();

    const Seen = struct {
        bold: bool = false,
        plain_stayed_plain: bool = true,
        italic: bool = false,
        underline: bool = false,

        fn visit(self: *@This(), row: u16, cells: []const Terminal.Cell) anyerror!void {
            _ = row;
            for (cells) |cell| {
                if (cell.codepoints.len == 0) continue;
                switch (cell.codepoints[0]) {
                    'B' => self.bold = cell.style.bold,
                    'b' => self.plain_stayed_plain = !cell.style.bold,
                    'C' => self.italic = cell.style.italic,
                    'D' => self.underline = cell.style.underline != 0,
                    else => {},
                }
            }
        }
    };
    var seen: Seen = .{};
    try terminal.visitRows(&seen, Seen.visit);
    // The style arrives through a sized struct. Leave the size unset and the
    // call fails, every attribute reads false, and nothing looks wrong until
    // a renderer draws a whole screen with no markup in it.
    try std.testing.expect(seen.bold);
    try std.testing.expect(seen.plain_stayed_plain);
    try std.testing.expect(seen.italic);
    try std.testing.expect(seen.underline);
}

test "the emulator reports colors a screen can be drawn with" {
    var terminal = try Terminal.init(std.testing.allocator, 4, 2);
    defer terminal.deinit();
    const colors = try terminal.colors();
    // The same trap as the style: a sized struct left unsized makes the call
    // fail and every color come back black, which reads as a theme rather
    // than as a bug.
    const back = colors.background;
    const front = colors.foreground;
    try std.testing.expect(back.r != front.r or back.g != front.g or back.b != front.b);
}

test "the scrollbar reports history once the screen overflows" {
    var terminal = try Terminal.init(std.testing.allocator, 16, 3);
    defer terminal.deinit();
    terminal.write("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");
    try terminal.update();
    const bar = try terminal.scrollbar();
    try std.testing.expect(bar.len > 0);
    // Five lines on a three-line screen: two rows are history the bar has to
    // account for, which is what makes it worth drawing.
    try std.testing.expect(bar.total > bar.len);
}

fn semanticOf(value: g.GhosttyCellSemanticContent) Terminal.Semantic {
    return switch (value) {
        g.GHOSTTY_CELL_SEMANTIC_INPUT => .input,
        g.GHOSTTY_CELL_SEMANTIC_PROMPT => .prompt,
        else => .output,
    };
}

test "a shell that marks its commands gives a result, and one that does not gives nothing" {
    var terminal = try Terminal.init(std.testing.allocator, 40, 6);
    defer terminal.deinit();
    // What a shell with OSC 133 emits: a prompt, a command the person typed and
    // ended with Enter, the output, and the command finishing.
    terminal.write("\x1b]133;A\x07$ \x1b]133;B\x07zig build test\r\n\x1b]133;C\x07error: 3 things\r\n\x1b]133;D;1\x07");
    try terminal.update();
    var result = (try terminal.lastCommand(std.testing.allocator)) orelse return error.TestExpectedResult;
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.command, "zig build test") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "error: 3 things") != null);

    // The same text without the markers is just text: a prompt that was never
    // announced is not a boundary, and guessing one would be inventing
    // evidence about what a command did.
    var plain = try Terminal.init(std.testing.allocator, 40, 6);
    defer plain.deinit();
    plain.write("$ zig build test\r\nerror: 3 things\r\n");
    try plain.update();
    try std.testing.expect((try plain.lastCommand(std.testing.allocator)) == null);
}

test "a selection is the text it covers, without the screen's padding" {
    var terminal = try Terminal.init(std.testing.allocator, 20, 4);
    defer terminal.deinit();
    terminal.write("first line\r\nsecond line\r\nthird");
    try terminal.update();

    // From the start of one line into the next: the first line is taken whole,
    // because a selection that spans rows takes all of the rows between.
    const across = try terminal.select(std.testing.allocator, .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 1 });
    defer std.testing.allocator.free(across);
    try std.testing.expectEqualStrings("first line\nsecond", across);

    // Part of one row only, and the row's padding is not part of it. Columns are
    // inclusive, so this is the second word and not the space before it.
    const word = try terminal.select(std.testing.allocator, .{ .x = 7, .y = 1 }, .{ .x = 10, .y = 1 });
    defer std.testing.allocator.free(word);
    try std.testing.expectEqualStrings("line", word);

    // A selection read backwards is the same selection.
    const reversed = try terminal.select(std.testing.allocator, .{ .x = 5, .y = 0 }, .{ .x = 0, .y = 0 });
    defer std.testing.allocator.free(reversed);
    try std.testing.expectEqualStrings("first", reversed);
}
