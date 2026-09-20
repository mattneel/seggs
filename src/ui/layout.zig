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

pub const Layout = struct {
    title: Rect,
    activity: Rect,
    explorer: Rect,
    editor: Rect,
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
    pub fn calculateDefault(width: f32, height: f32, sidebar: bool) Layout {
        return calculate(width, height, sidebar, .{ .line_height = 22, .char_width = 9.5 });
    }

    pub fn calculate(width: f32, height: f32, sidebar: bool, metrics: Metrics) Layout {
        const title_h = @round(metrics.line_height * 2);
        const status_h = @round(metrics.line_height * 1.25);
        const body_h = @max(0, height - title_h - status_h);
        const rail = @round(metrics.char_width * 4.5);
        const left: f32 = if (sidebar and width >= explorer_breakpoint) @round(metrics.char_width * 22) else 0;
        const right = if (width < agents_breakpoint) 0 else @min(460, @max(280, width * 0.34));
        return .{
            .title = .{ .x = 0, .y = 0, .w = width, .h = title_h },
            .activity = .{ .x = 0, .y = title_h, .w = rail, .h = body_h },
            .explorer = .{ .x = rail, .y = title_h, .w = left, .h = body_h },
            .editor = .{ .x = rail + left, .y = title_h, .w = @max(0, width - rail - left - right), .h = body_h },
            .agents = .{ .x = width - right, .y = title_h, .w = right, .h = body_h },
            .status = .{ .x = 0, .y = height - status_h, .w = width, .h = status_h },
        };
    }
};

test "panels tile the window" {
    const l = Layout.calculateDefault(1440, 900, true);
    try std.testing.expectEqual(@as(f32, 1440), l.activity.w + l.explorer.w + l.editor.w + l.agents.w);
    try std.testing.expectEqual(@as(f32, 900), l.title.h + l.editor.h + l.status.h);
    try std.testing.expectEqual(@as(f32, 0), Layout.calculateDefault(900, 700, true).explorer.w);
}
test "columns drop as the window narrows, and the editor keeps the space" {
    const metrics: Layout.Metrics = .{ .line_height = 22, .char_width = 9.5 };
    const wide = Layout.calculate(1440, 900, true, metrics);
    try std.testing.expect(wide.explorer.w > 0 and wide.agents.w > 0);
    // Between the breakpoints the agent column fits but the file list does not.
    const agents_only = Layout.calculate(1000, 700, true, metrics);
    try std.testing.expect(agents_only.agents.w > 0);
    try std.testing.expectEqual(@as(f32, 0), agents_only.explorer.w);
    // Under both, the editor takes everything beside the rail.
    const narrow = Layout.calculate(860, 600, true, metrics);
    try std.testing.expectEqual(@as(f32, 0), narrow.explorer.w);
    try std.testing.expectEqual(@as(f32, 0), narrow.agents.w);
    try std.testing.expectEqual(@as(f32, 860), narrow.activity.w + narrow.editor.w);
    // Whatever the size, the columns fill the window exactly.
    for ([_]f32{ 640, 800, 900, 1040, 1200, 1440, 1920 }) |width| {
        for ([_]f32{ 420, 700, 900, 1200 }) |height| {
            const l = Layout.calculate(width, height, true, metrics);
            try std.testing.expectEqual(width, l.activity.w + l.explorer.w + l.editor.w + l.agents.w);
            try std.testing.expectEqual(height, l.title.h + l.editor.h + l.status.h);
        }
    }
}

test "chrome follows the cell metrics" {
    // A larger font moves the bars and the rail with it.
    const big = Layout.calculate(1440, 900, true, .{ .line_height = 44, .char_width = 19 });
    const small = Layout.calculate(1440, 900, true, .{ .line_height = 22, .char_width = 9.5 });
    try std.testing.expect(big.title.h > small.title.h);
    try std.testing.expect(big.status.h > small.status.h);
    try std.testing.expect(big.activity.w > small.activity.w);
    try std.testing.expect(big.explorer.w > small.explorer.w);
}
