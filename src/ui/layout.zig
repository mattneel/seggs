const std = @import("std");

pub const Rect = struct {
    x: f32, y: f32, w: f32, h: f32,
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
    pub fn calculate(width: f32, height: f32, sidebar: bool) Layout {
        const title_h: f32 = 42;
        const status_h: f32 = 28;
        const body_h = @max(0, height - title_h - status_h);
        const rail: f32 = 44;
        const left: f32 = if (sidebar and width >= 1050) 216 else 0;
        const right = @min(460, @max(280, width * 0.34));
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
    const l = Layout.calculate(1440, 900, true);
    try std.testing.expectEqual(@as(f32, 1440), l.activity.w + l.explorer.w + l.editor.w + l.agents.w);
    try std.testing.expectEqual(@as(f32, 900), l.title.h + l.editor.h + l.status.h);
    try std.testing.expectEqual(@as(f32, 0), Layout.calculate(900, 700, true).explorer.w);
}
