const std = @import("std");
const g = @import("ghostty");

/// A terminal: libghostty-vt's emulator state, the render state a surface draws
/// from, and the encoder that turns input into the bytes a program expects.
///
/// The library is C and is built by the Zig release Ghostty pins (see
/// tools/bootstrap.py). Nothing here allocates through the library except
/// through its default allocator, which is what the library's own examples do.
pub const Terminal = struct {
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
    key_encoder: g.GhosttyKeyEncoder = null,
    key_event: g.GhosttyKeyEvent = null,
    mouse_encoder: g.GhosttyMouseEncoder = null,
    cell_width: u32 = 1,
    cell_height: u32 = 1,

    /// What a surface needs to know about a frame before it draws.
    pub const Dirty = enum { clean, partial, full };

    /// One cell of the grid, as the renderer wants it.
    pub const Cell = struct {
        /// The grapheme's codepoints. Empty means the cell drew nothing.
        codepoints: []const u32,
        style: g.GhosttyStyle,
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

    pub fn init(initial_cols: u16, initial_rows: u16) !Terminal {
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
        return .{ .handle = handle, .render = render, .row_iterator = iterator, .row_cells = cells };
    }

    pub fn deinit(self: *Terminal) void {
        if (self.key_event != null) g.ghostty_key_event_free(self.key_event);
        if (self.key_encoder != null) g.ghostty_key_encoder_free(self.key_encoder);
        if (self.mouse_encoder != null) g.ghostty_mouse_encoder_free(self.mouse_encoder);
        g.ghostty_render_state_row_cells_free(self.row_cells);
        g.ghostty_render_state_row_iterator_free(self.row_iterator);
        g.ghostty_render_state_free(self.render);
        g.ghostty_terminal_free(self.handle);
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

    pub fn colors(self: *Terminal) Colors {
        self.colors_cache = std.mem.zeroInit(g.GhosttyRenderStateColors, .{});
        var out = std.mem.zeroInit(g.GhosttyRenderStateColors, .{});
        _ = g.ghostty_render_state_colors_get(self.render, @ptrCast(&out));
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
                var grapheme_len: u32 = 0;
                _ = g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&grapheme_len));
                var style = std.mem.zeroInit(g.GhosttyStyle, .{});
                if (grapheme_len != 0) {
                    const take = @min(grapheme_len, max_graphemes);
                    _ = g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, @ptrCast(&self.grapheme_storage[count]));
                    _ = g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, @ptrCast(&style));
                    self.cell_storage[count] = .{ .codepoints = self.grapheme_storage[count][0..take], .style = style };
                } else {
                    self.cell_storage[count] = .{ .codepoints = &.{}, .style = style };
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
    pub fn encodePaste(self: *Terminal, text: []const u8, out: []u8) ![]u8 {
        var written: usize = 0;
        const result = g.ghostty_paste_encode(
            @constCast(text.ptr),
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

    /// Move the viewport through scrollback. Negative scrolls up into history,
    /// which is what a wheel does; the program's own screen is untouched.
    pub fn scroll(self: *Terminal, lines: isize) void {
        const request = g.GhosttyTerminalScrollViewport{
            .tag = @intCast(g.GHOSTTY_SCROLL_VIEWPORT_DELTA),
            .value = .{ .delta = lines },
        };
        g.ghostty_terminal_scroll_viewport(self.handle, request);
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
    var terminal = try Terminal.init(20, 4);
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
    var terminal = try Terminal.init(20, 4);
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
    var terminal = try Terminal.init(80, 24);
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
    var terminal = try Terminal.init(16, 3);
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
