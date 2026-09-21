const std = @import("std");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
    pub fn inset(self: Rect, n: f32) Rect {
        return .{ .x = self.x + n, .y = self.y + n, .w = @max(0, self.w - 2 * n), .h = @max(0, self.h - 2 * n) };
    }
};

/// Kept between two bounds, in that order, even when the bounds themselves cross.
fn clamp(value: f32, low: f32, high: f32) f32 {
    return @max(low, @min(high, value));
}

pub const Layout = struct {
    activity: Rect,
    explorer: Rect,
    editor: Rect,
    /// The terminal dock below the editor. Empty when the dock is closed, and
    /// the editor then keeps the whole body.
    terminal: Rect,
    agents: Rect,
    status: Rect,
    /// Cell metrics the shell is sized from, so a different font size or display
    /// density moves the chrome with the text instead of against it.
    pub const Metrics = struct { line_height: f32, char_width: f32 };

    /// Below this width the agents pane is dropped and the editor takes its
    /// space: three columns in a narrow window leave none of them usable.
    pub const agents_breakpoint: f32 = 880;
    /// Below this width the file list joins it, leaving rail and editor.
    pub const explorer_breakpoint: f32 = 1040;

    /// The metrics the shell uses with its default font, for callers that only
    /// need a layout and tests that check the shape of one.
    /// The tab strip along the top of the terminal dock. It belongs to the dock
    /// rather than to the screen inside it, and the grid starts under it.
    pub const terminal_strip_height: f32 = 26;

    /// The part of the dock the shell's screen occupies. The size the shell is
    /// told and the place its output is drawn have to be the same rectangle, or
    /// the program lays out rows for space the reader cannot see - which is how a
    /// prompt ends up underneath the tabs.
    pub fn terminalScreen(dock: Rect) Rect {
        return .{
            .x = dock.x,
            .y = dock.y + terminal_strip_height,
            .w = dock.w,
            .h = @max(0, dock.h - terminal_strip_height),
        };
    }

    pub fn calculateDefault(width: f32, height: f32, sidebar: bool) Layout {
        return calculate(width, height, sidebar, .{ .line_height = 22, .char_width = 9.5 }, 0);
    }

    /// What a reader has dragged a dock to, if anything. Null means the dock is
    /// the width this layout would choose, which is what keeps a window resize
    /// working after a drag.
    pub const Resize = struct {
        /// Whether the agent dock is on screen at all. There is no agent panel
        /// with no agents in it, the way there is no terminal dock with no shells:
        /// an empty column of chrome is room taken from the editor to say nothing.
        agents_open: bool = true,

        explorer: ?f32 = null,
        agents: ?f32 = null,

        /// The least a dock may be dragged to, and the least the editor keeps
        /// when one is dragged wide: a dock that swallows the code is not a
        /// layout, it is a mistake.
        pub const min_explorer: f32 = 160;
        pub const min_agents: f32 = 240;
        pub const min_editor: f32 = 200;
    };

    pub fn calculate(width: f32, height: f32, sidebar: bool, metrics: Metrics, dock: f32) Layout {
        return calculateResized(width, height, sidebar, metrics, dock, .{});
    }

    /// `dock` is the fraction of the body the terminal takes, zero when it is
    /// closed. It splits the editor's column rather than the window, so the
    /// file list and the agent column keep their heights.
    ///
    /// `resize` is what the reader dragged: a dock may be any width that leaves
    /// the editor room to be an editor, and a drag outside that range lands on
    /// the edge rather than on something absurd.
    pub fn calculateResized(width: f32, height: f32, sidebar: bool, metrics: Metrics, dock: f32, resize: Resize) Layout {
        // No title bar: the space it took is worth more than the name of the
        // program drawing it.
        const status_h = @round(metrics.line_height * 1.25);
        const body_h = @max(0, height - status_h);
        const rail = @round(metrics.char_width * 4.5);
        // The navigator and the agent dock are docks, not proportions: a column
        // of filenames and a column of labels read the same at any window size,
        // and the editor takes what is left.
        // Each dock is bounded by what the other one has already taken: a drag
        // that ignored its neighbour would push the editor off the window even
        // though the dock itself was within its own limits.
        const left_wanted = @max(220, @min(260, width * 0.20));
        const right_wanted = @max(300, @min(360, width * 0.26));
        const left_room = width - rail - right_wanted - Resize.min_editor;
        const left: f32 = if (sidebar and width >= explorer_breakpoint)
            @round(clamp(resize.explorer orelse left_wanted, Resize.min_explorer, @max(Resize.min_explorer, left_room)))
        else
            0;
        const right_room = width - rail - left - Resize.min_editor;
        const right = if (!resize.agents_open or width < agents_breakpoint)
            0
        else
            @round(clamp(resize.agents orelse right_wanted, Resize.min_agents, @max(Resize.min_agents, right_room)));
        const editor_w = @max(0, width - rail - left - right);
        // A few rows is the least a terminal can be read in, and the editor
        // keeps at least as much, so the dock never swallows the code.
        const dock_h = if (dock <= 0) 0 else @min(body_h / 2, @max(metrics.line_height * 3, @round(body_h * dock)));
        return .{
            .activity = .{ .x = 0, .y = 0, .w = rail, .h = body_h },
            .explorer = .{ .x = rail, .y = 0, .w = left, .h = body_h },
            .editor = .{ .x = rail + left, .y = 0, .w = editor_w, .h = body_h - dock_h },
            .terminal = .{ .x = rail + left, .y = body_h - dock_h, .w = editor_w, .h = dock_h },
            .agents = .{ .x = width - right, .y = 0, .w = right, .h = body_h },
            .status = .{ .x = 0, .y = height - status_h, .w = width, .h = status_h },
        };
    }
};

test "a closed agent dock leaves its room to the editor" {
    const metrics: Layout.Metrics = .{ .line_height = 22, .char_width = 9.5 };
    const open = Layout.calculateResized(1440, 900, true, metrics, 0, .{});
    const closed = Layout.calculateResized(1440, 900, true, metrics, 0, .{ .agents_open = false });
    // A panel with nothing in it is a column of chrome that costs the editor
    // its room and says nothing with it.
    try std.testing.expect(open.agents.w > 0);
    try std.testing.expectEqual(@as(f32, 0), closed.agents.w);
    try std.testing.expect(closed.editor.w > open.editor.w);
    try std.testing.expectEqual(@as(f32, 1440), closed.activity.w + closed.explorer.w + closed.editor.w);
}

test "the shell's screen sits below the tab strip and fits inside the dock" {
    const dock: Rect = .{ .x = 100, .y = 500, .w = 600, .h = 216 };
    const screen = Layout.terminalScreen(dock);
    // The strip is the dock's, so the screen starts under it and is shorter by
    // exactly that much. A grid told it has the strip's rows too draws its
    // first line where the tabs are, which is a prompt nobody can see.
    try std.testing.expectEqual(dock.y + Layout.terminal_strip_height, screen.y);
    try std.testing.expectEqual(dock.h - Layout.terminal_strip_height, screen.h);
    try std.testing.expectEqual(dock.w, screen.w);
    // Whole rows have to fit, at the height the shell is told about.
    const rows = @floor((screen.h - 8) / 22);
    try std.testing.expect(rows * 22 <= screen.h);
    // A dock too short for a strip leaves nothing rather than a negative box.
    try std.testing.expectEqual(@as(f32, 0), Layout.terminalScreen(.{ .x = 0, .y = 0, .w = 10, .h = 10 }).h);
}

test "panels tile the window" {
    const l = Layout.calculateDefault(1440, 900, true);
    try std.testing.expectEqual(@as(f32, 1440), l.activity.w + l.explorer.w + l.editor.w + l.agents.w);
    try std.testing.expectEqual(@as(f32, 900), l.editor.h + l.terminal.h + l.status.h);
    try std.testing.expectEqual(@as(f32, 0), Layout.calculateDefault(900, 700, true).explorer.w);
}
test "columns drop as the window narrows, and the editor keeps the space" {
    const metrics: Layout.Metrics = .{ .line_height = 22, .char_width = 9.5 };
    const wide = Layout.calculate(1440, 900, true, metrics, 0);
    try std.testing.expect(wide.explorer.w > 0 and wide.agents.w > 0);
    // Between the breakpoints the agent column fits but the file list does not.
    const agents_only = Layout.calculate(1000, 700, true, metrics, 0);
    try std.testing.expect(agents_only.agents.w > 0);
    try std.testing.expectEqual(@as(f32, 0), agents_only.explorer.w);
    // Under both, the editor takes everything beside the rail.
    const narrow = Layout.calculate(860, 600, true, metrics, 0);
    try std.testing.expectEqual(@as(f32, 0), narrow.explorer.w);
    try std.testing.expectEqual(@as(f32, 0), narrow.agents.w);
    try std.testing.expectEqual(@as(f32, 860), narrow.activity.w + narrow.editor.w);
    // Whatever the size, the columns fill the window exactly.
    for ([_]f32{ 640, 800, 900, 1040, 1200, 1440, 1920 }) |width| {
        for ([_]f32{ 420, 700, 900, 1200 }) |height| {
            const l = Layout.calculate(width, height, true, metrics, 0);
            try std.testing.expectEqual(width, l.activity.w + l.explorer.w + l.editor.w + l.agents.w);
            try std.testing.expectEqual(height, l.editor.h + l.terminal.h + l.status.h);
        }
    }
}

test "chrome follows the cell metrics" {
    // A larger font moves the bars and the rail with it.
    const big = Layout.calculate(1440, 900, true, .{ .line_height = 44, .char_width = 19 }, 0);
    const small = Layout.calculate(1440, 900, true, .{ .line_height = 22, .char_width = 9.5 }, 0);
    try std.testing.expect(big.status.h > small.status.h);
    try std.testing.expect(big.activity.w > small.activity.w);
}

test "a dragged dock stops where the editor would be squeezed out" {
    const metrics: Layout.Metrics = .{ .line_height = 22, .char_width = 9.5 };
    // Dragged as wide as it will go: the editor keeps its room.
    const wide = Layout.calculateResized(1200, 800, true, metrics, 0, .{ .explorer = 100_000 });
    try std.testing.expect(wide.editor.w >= Layout.Resize.min_editor - 1);
    // Dragged narrower than a column of names can be read in.
    const narrow = Layout.calculateResized(1200, 800, true, metrics, 0, .{ .explorer = 10 });
    try std.testing.expectEqual(Layout.Resize.min_explorer, narrow.explorer.w);
    // The same on the other side, which also has to leave the editor alone.
    const right = Layout.calculateResized(1200, 800, true, metrics, 0, .{ .agents = 100_000 });
    try std.testing.expect(right.editor.w >= Layout.Resize.min_editor - 1);
    const small = Layout.calculateResized(1200, 800, true, metrics, 0, .{ .agents = 1 });
    try std.testing.expectEqual(Layout.Resize.min_agents, small.agents.w);
    // A width the reader chose is the width they get.
    const chosen = Layout.calculateResized(1200, 800, true, metrics, 0, .{ .explorer = 300 });
    try std.testing.expectEqual(@as(f32, 300), chosen.explorer.w);
}

test "the docks stay readable and the editor takes the rest" {
    // A navigator and a dock of labels are columns, not proportions: widening
    // the window past their bounds hands the room to the editor.
    const metrics: Layout.Metrics = .{ .line_height = 22, .char_width = 9.5 };
    const wide = Layout.calculate(1920, 900, true, metrics, 0);
    const wider = Layout.calculate(2560, 900, true, metrics, 0);
    try std.testing.expect(wide.explorer.w >= 220 and wide.explorer.w <= 260);
    try std.testing.expect(wide.agents.w >= 300 and wide.agents.w <= 360);
    try std.testing.expectEqual(wide.explorer.w, wider.explorer.w);
    try std.testing.expectEqual(wide.agents.w, wider.agents.w);
    try std.testing.expect(wider.editor.w > wide.editor.w);
}

test "the terminal dock splits the editor column and closes to nothing" {
    const metrics: Layout.Metrics = .{ .line_height = 22, .char_width = 9.5 };
    const closed = Layout.calculate(1440, 900, true, metrics, 0);
    try std.testing.expectEqual(@as(f32, 0), closed.terminal.h);
    try std.testing.expectEqual(closed.editor.h, Layout.calculate(1440, 900, true, metrics, 0).editor.h);

    const open = Layout.calculate(1440, 900, true, metrics, 0.25);
    try std.testing.expect(open.terminal.h > 0);
    // The editor and the dock still fill the body, and the dock sits directly
    // below the editor rather than floating in it.
    try std.testing.expectEqual(open.editor.h + open.terminal.h, 900 - open.status.h);
    try std.testing.expectEqual(open.editor.y + open.editor.h, open.terminal.y);
    try std.testing.expectEqual(open.editor.w, open.terminal.w);
    try std.testing.expectEqual(open.editor.x, open.terminal.x);
    // Neighbours keep their full height whichever way the dock is set.
    try std.testing.expectEqual(closed.explorer.h, open.explorer.h);
    try std.testing.expectEqual(closed.agents.h, open.agents.h);
    // The dock never takes more than half the body, however large the fraction.
    const greedy = Layout.calculate(1440, 900, true, metrics, 0.9);
    try std.testing.expect(greedy.terminal.h <= (900 - greedy.status.h) / 2 + 1);
}
