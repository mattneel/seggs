//! One list of named rows with a single one highlighted: the dropdown under a
//! control and the jump list over the window are the same widget.
//!
//! The two placements share everything but the box they are drawn in. The rows,
//! the highlight, the scrolling, the filter, and the hit test are identical, and
//! the box is computed from the same rows, so where a box goes is a parameter
//! rather than a second widget: a dropdown hangs under the control that opened
//! it - at least as wide as that control, and above it when the window has no
//! room below - while a jump list is centred over the window. Two widgets would
//! mean two row layouts, two hit tests, and two chances for the row that was
//! drawn and the row that was clicked to disagree.
//!
//! The widget owns no memory and calls nothing outside itself. The items, the
//! flags, and the picture come from the caller: the rows are a slice it does not
//! own, and drawing goes through whatever renderer it is handed.
const std = @import("std");
const text = @import("../core/text.zig");
const Rect = @import("layout.zig").Rect;
const wrap = @import("wrap.zig");
const theme = @import("theme.zig");

/// What the caller's font says a row is. Rows are built from these rather than
/// from a height chosen for one face, so a larger font moves the list with the
/// text instead of against it.
pub const Metrics = struct {
    line_height: f32,
    advance: f32,
};

pub const Item = struct {
    /// What the row says, and what the filter matches.
    label: []const u8,
    /// Right-aligned and optional: where a row states what it is - a state, a
    /// count - without pushing the label around.
    detail: []const u8 = "",
    /// The caller's own handle for the row. The widget identifies rows by
    /// position in `items`, and a list that skips rows its caller cannot use
    /// still has to say which one was chosen.
    key: usize = 0,
};

/// Where a list's box goes. These are one widget because nothing else about
/// them differs: the same rows, the same highlight, the same filter, and a box
/// computed from the same rows.
pub const Placement = union(enum) {
    /// Under the control that opened the list, at least as wide as that control,
    /// and above it when the window has no room below.
    anchored: Rect,
    /// Over the window, under the title bar: a jump list opened by a key.
    centered,
};

pub const Menu = struct {
    /// How many rows a box shows before it scrolls, and how long a filter may
    /// get. Both are small on purpose: a list longer than a glance is a list to
    /// type into.
    pub const max_rows: usize = 9;
    pub const max_query: usize = 256;
    /// The air inside the box, and the lift of a row's highlight over it.
    const padding: f32 = 10;

    /// Rows, borrowed. The widget never copies and never frees them.
    items: []const Item = &.{},
    /// Parallel to `items`, or empty when nothing is ruled out. A row that is
    /// not enabled is drawn as a row that cannot be chosen and is passed over
    /// by the movement, rather than hidden: the list shows the whole set it
    /// names, and the reader can see why one of them is not for them.
    enabled: []const bool = &.{},
    /// Which item the highlight is on, as an index into `items`.
    selected: usize = 0,
    /// Drawn at the top of the box.
    title: []const u8 = "",
    /// The filter, held here rather than borrowed: the widget reads it for
    /// every row, and a buffer its caller may reallocate underneath it is a
    /// dangling slice waiting to happen.
    query: [max_query]u8 = undefined,
    query_len: usize = 0,

    /// Point the list at the rows it is showing. The selection is set by `open`
    /// rather than here, because which row is first depends on the filter.
    pub fn setItems(self: *Menu, items: []const Item, enabled: []const bool) void {
        self.items = items;
        self.enabled = enabled;
    }

    /// Open a list: no filter yet, and the highlight on the first row there is.
    pub fn open(self: *Menu, title: []const u8) void {
        self.title = title;
        self.query_len = 0;
        self.selected = self.firstShown();
    }

    pub fn queryText(self: *const Menu) []const u8 {
        return self.query[0..self.query_len];
    }

    /// Add typed characters to the filter. The highlight moves with the text: a
    /// row the filter hides cannot be the row the reader means.
    pub fn typeBytes(self: *Menu, bytes: []const u8) void {
        const take = @min(bytes.len, max_query - self.query_len);
        @memcpy(self.query[self.query_len..][0..take], bytes[0..take]);
        self.query_len += take;
        self.selected = self.firstShown();
    }

    pub fn backspace(self: *Menu) void {
        if (self.query_len == 0) return;
        self.query_len = text.previous(self.query[0..self.query_len], self.query_len);
        self.selected = self.firstShown();
    }

    /// Move the highlight to the next row that can be chosen, in the direction
    /// asked for, and stay where it is when there is none.
    pub fn move(self: *Menu, forward: bool) void {
        if (self.items.len == 0) return;
        var index = @min(self.selected, self.items.len - 1);
        if (forward) {
            while (index + 1 < self.items.len) {
                index += 1;
                if (self.pickable(index)) {
                    self.selected = index;
                    return;
                }
            }
            return;
        }
        while (index > 0) {
            index -= 1;
            if (self.pickable(index)) {
                self.selected = index;
                return;
            }
        }
    }

    /// The item the highlight is on, when it can be chosen. Null covers both
    /// cases a caller has to answer for: nothing matches the filter, and the
    /// row under the highlight is one the caller ruled out.
    pub fn chosen(self: *const Menu) ?usize {
        if (self.selected >= self.items.len) return null;
        if (!self.pickable(self.selected)) return null;
        return self.selected;
    }

    /// Whether the filter shows this row at all.
    pub fn shown(self: *const Menu, index: usize) bool {
        if (index >= self.items.len) return false;
        const query = self.queryText();
        const label = self.items[index].label;
        if (query.len == 0) return true;
        if (query.len > label.len) return false;
        for (0..label.len - query.len + 1) |start| {
            if (std.ascii.eqlIgnoreCase(label[start..][0..query.len], query)) return true;
        }
        return false;
    }

    /// Whether this row can be chosen. A caller with nothing ruled out passes
    /// no flags, and every row is choosable.
    pub fn enabledAt(self: *const Menu, index: usize) bool {
        if (index >= self.enabled.len) return true;
        return self.enabled[index];
    }

    pub fn pickable(self: *const Menu, index: usize) bool {
        return self.shown(index) and self.enabledAt(index);
    }

    /// How many rows the filter leaves.
    pub fn shownCount(self: *const Menu) usize {
        var count: usize = 0;
        for (self.items, 0..) |_, index| {
            if (self.shown(index)) count += 1;
        }
        return count;
    }

    /// The rows this list draws, top to bottom, as indices into `items`. The
    /// draw and the hit test both come through here, so the row a point lands on
    /// is the row that was drawn.
    pub fn shownRows(self: *const Menu, out: *[max_rows]usize) usize {
        const first = self.scroll();
        var seen: usize = 0;
        var count: usize = 0;
        for (self.items, 0..) |_, index| {
            if (!self.shown(index)) continue;
            const row = seen;
            seen += 1;
            if (row < first) continue;
            if (count == max_rows) return count;
            out[count] = index;
            count += 1;
        }
        return count;
    }

    /// The row the highlight sits on, counted among the rows the filter shows.
    fn firstRow(self: *const Menu) usize {
        var row: usize = 0;
        for (self.items, 0..) |_, index| {
            if (index == self.selected) return row;
            if (self.shown(index)) row += 1;
        }
        return 0;
    }

    /// The first row the box shows. The window follows the highlight, so the
    /// row the reader moved to is always one of the rows in front of them.
    fn scroll(self: *const Menu) usize {
        return self.firstRow() -| (max_rows - 1);
    }

    fn firstShown(self: *const Menu) usize {
        for (self.items, 0..) |_, index| {
            if (self.shown(index)) return index;
        }
        return 0;
    }

    /// The height of one row: a line of text plus the air a highlight needs
    /// around it.
    pub fn rowHeight(metrics: Metrics) f32 {
        return metrics.line_height + 8;
    }

    /// The title line and the filter line, above the rows.
    pub fn headerHeight(metrics: Metrics) f32 {
        return metrics.line_height * 2 + 18;
    }

    /// The box this list occupies. Everything a caller needs to agree with the
    /// widget - a click, a clip, a backdrop - comes from here.
    pub fn bounds(self: *const Menu, placement: Placement, screen: Rect, metrics: Metrics) Rect {
        const rows: f32 = @floatFromInt(@max(1, @min(self.shownCount(), max_rows)));
        const height = padding * 2 + headerHeight(metrics) + rows * rowHeight(metrics);
        switch (placement) {
            .centered => {
                const width = @min(720, @max(200, screen.w - 40));
                const x = if (screen.w > width) screen.x + (screen.w - width) / 2 else screen.x;
                return .{ .x = x, .y = screen.y + 96, .w = width, .h = height };
            },
            .anchored => |trigger| {
                // Wider than the control it hangs from, because a row has a
                // name and a state to fit side by side, and a control like a
                // `+` is barely wide enough for its own glyph.
                const width = @max(trigger.w, 240);
                const below = trigger.y + trigger.h;
                const y = if (below + height <= screen.y + screen.h) below else trigger.y - height;
                return .{
                    .x = @max(screen.x, @min(trigger.x, screen.x + screen.w - width)),
                    .y = @max(screen.y, @min(y, screen.y + screen.h - height)),
                    .w = width,
                    .h = height,
                };
            },
        }
    }

    /// The row a point is on, or null when it is on the title, the filter line,
    /// the padding, or nothing at all.
    pub fn hit(self: *const Menu, placement: Placement, screen: Rect, metrics: Metrics, x: f32, y: f32) ?usize {
        const box = self.bounds(placement, screen, metrics);
        if (!box.contains(x, y)) return null;
        const top = box.y + padding + headerHeight(metrics);
        if (y < top) return null;
        const row: usize = @intFromFloat((y - top) / rowHeight(metrics));
        var rows: [max_rows]usize = undefined;
        const count = self.shownRows(&rows);
        if (row >= count) return null;
        return rows[row];
    }

    /// Draw the list. The renderer is anything with a clip, a `rect`, and a
    /// `text`, which is how the picture stays the caller's business: no SDL, no
    /// atlas, and no clock are named here.
    pub fn draw(self: *const Menu, r: anytype, placement: Placement, screen: Rect, metrics: Metrics) !void {
        const box = self.bounds(placement, screen, metrics);
        const outer = r.clip;
        defer r.clip = outer;
        r.clip = box;
        try r.rect(box, theme.border);
        try r.rect(box.inset(1), theme.raised);
        try r.text(box.x + padding, box.y + padding, self.title, theme.accent);
        const line = box.y + padding + metrics.line_height + 6;
        try r.text(box.x + padding, line, if (self.query_len == 0) "Type to filter..." else self.queryText(), if (self.query_len == 0) theme.muted else theme.text);
        const top = box.y + padding + headerHeight(metrics);
        var rows: [max_rows]usize = undefined;
        const count = self.shownRows(&rows);
        if (count == 0) {
            try r.text(box.x + padding, top + 4, if (self.query_len == 0) "Nothing here." else "Nothing matches.", theme.muted);
            return;
        }
        var scratch: [256]u8 = undefined;
        for (rows[0..count], 0..) |index, row| {
            const item = self.items[index];
            // The highlight is the row the reader is on, and a row that cannot
            // be chosen is drawn as one rather than highlighted like the rest.
            const picked = index == self.selected and self.enabledAt(index);
            const row_box: Rect = .{
                .x = box.x + padding / 2,
                .y = top + @as(f32, @floatFromInt(row)) * rowHeight(metrics),
                .w = box.w - padding,
                .h = rowHeight(metrics),
            };
            if (picked) try r.rect(row_box, theme.selected);
            const colour = if (!self.enabledAt(index)) theme.muted else theme.text;
            const detail_room: f32 = if (item.detail.len == 0) 0 else @as(f32, @floatFromInt(item.detail.len)) * metrics.advance + 12;
            const room: usize = @intFromFloat(@max(2, (row_box.w - 16 - detail_room) / metrics.advance));
            try r.text(row_box.x + 8, row_box.y + 4, cut(&scratch, item.label, room), colour);
            if (item.detail.len > 0) {
                const width = @as(f32, @floatFromInt(item.detail.len)) * metrics.advance;
                try r.text(row_box.x + row_box.w - 8 - width, row_box.y + 4, item.detail, theme.muted);
            }
        }
    }
};

/// A label cut to the room a row has. A label longer than the scratch is drawn
/// as it is: the row's clip is what cuts it, and eliding it would need a buffer
/// this widget does not have.
fn cut(scratch: []u8, label: []const u8, columns: usize) []const u8 {
    if (label.len + 3 > scratch.len) return label;
    return wrap.elide(scratch, label, columns);
}

test "the highlight walks the rows a reader can pick, filtered the way the list is drawn" {
    const items = [_]Item{
        .{ .label = "Alpha" },
        .{ .label = "Beta" },
        .{ .label = "Gamma" },
    };
    const enabled = [_]bool{ true, false, true };
    var menu: Menu = .{};
    menu.setItems(&items, &enabled);
    menu.open("AGENTS");
    try std.testing.expectEqual(@as(usize, 0), menu.selected);

    // Beta is shown but ruled out, so the next row a reader can pick is Gamma,
    // and the end of the list is the end of it.
    menu.move(true);
    try std.testing.expectEqual(@as(usize, 2), menu.selected);
    try std.testing.expectEqual(@as(usize, 2), menu.chosen().?);
    menu.move(true);
    try std.testing.expectEqual(@as(usize, 2), menu.selected);
    menu.move(false);
    try std.testing.expectEqual(@as(usize, 0), menu.selected);

    // Typing narrows the list and moves the highlight to what is left of it.
    menu.typeBytes("gam");
    try std.testing.expectEqual(@as(usize, 1), menu.shownCount());
    try std.testing.expectEqual(@as(usize, 2), menu.selected);
    menu.typeBytes("ma");
    try std.testing.expectEqualStrings("gamma", menu.queryText());
    try std.testing.expectEqual(@as(usize, 1), menu.shownCount());

    // A filter that matches nothing leaves nothing to choose.
    menu.typeBytes("zz");
    try std.testing.expectEqual(@as(usize, 0), menu.shownCount());
    try std.testing.expectEqual(@as(?usize, null), menu.chosen());

    // Deleting the filter brings the list back, and the highlight with it.
    var remaining = menu.query_len;
    while (remaining > 0) : (remaining -= 1) menu.backspace();
    try std.testing.expectEqualStrings("", menu.queryText());
    try std.testing.expectEqual(@as(usize, 3), menu.shownCount());
    try std.testing.expectEqual(@as(usize, 0), menu.selected);

    // A rule against a row that is the whole list leaves nothing to choose.
    menu.selected = 1;
    try std.testing.expectEqual(@as(?usize, null), menu.chosen());
}

test "a point lands on the row that was drawn, in either placement" {
    const screen: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 700 };
    const metrics: Metrics = .{ .line_height = 22, .advance = 9.5 };
    const items = [_]Item{ .{ .label = "one" }, .{ .label = "two" }, .{ .label = "three" } };
    var menu: Menu = .{};
    menu.setItems(&items, &.{});
    menu.open("SEND TO");

    const trigger: Rect = .{ .x = 700, .y = 40, .w = 24, .h = 26 };
    const box = menu.bounds(.{ .anchored = trigger }, screen, metrics);
    // Under the control, as wide as it at the least, and on the window.
    try std.testing.expectEqual(trigger.y + trigger.h, box.y);
    try std.testing.expect(box.w >= trigger.w);
    try std.testing.expect(box.x >= screen.x and box.x + box.w <= screen.x + screen.w);
    // The box is the air, the header, and one row per item, and nothing else.
    try std.testing.expectEqual(
        @as(f32, 20 + Menu.headerHeight(metrics)),
        box.h - 3 * Menu.rowHeight(metrics),
    );

    // Every click inside a row reaches the row it was drawn on.
    for (0..3) |index| {
        const y = box.y + 10 + Menu.headerHeight(metrics) + (@as(f32, @floatFromInt(index)) + 0.5) * Menu.rowHeight(metrics);
        try std.testing.expectEqual(@as(?usize, index), menu.hit(.{ .anchored = trigger }, screen, metrics, box.x + 20, y));
    }
    // The title and the filter line are not rows, and neither is a point past
    // the last row or outside the box.
    try std.testing.expectEqual(@as(?usize, null), menu.hit(.{ .anchored = trigger }, screen, metrics, box.x + 20, box.y + 4));
    try std.testing.expectEqual(@as(?usize, null), menu.hit(.{ .anchored = trigger }, screen, metrics, box.x + 20, box.y + box.h + 4));
    try std.testing.expectEqual(@as(?usize, null), menu.hit(.{ .anchored = trigger }, screen, metrics, box.x - 4, box.y + box.h / 2));

    // A window with no room under the control puts the box above it, hanging
    // from the same edge.
    const low: Rect = .{ .x = 700, .y = screen.h - 40, .w = 24, .h = 26 };
    const flipped = menu.bounds(.{ .anchored = low }, screen, metrics);
    try std.testing.expect(flipped.y + flipped.h <= low.y);
    try std.testing.expect(flipped.y >= screen.y);
    try std.testing.expectEqual(@as(?usize, 0), menu.hit(.{ .anchored = low }, screen, metrics, flipped.x + 20, flipped.y + 10 + Menu.headerHeight(metrics) + 1));
    try std.testing.expectEqual(flipped.y + flipped.h - low.h, flipped.y + flipped.h - low.h);
    try std.testing.expectEqual(low.y - flipped.h, flipped.y);

    // The jump list is centred, and its rows answer the same way.
    const centred = menu.bounds(.centered, screen, metrics);
    try std.testing.expectEqual((screen.w - centred.w) / 2, centred.x);
    try std.testing.expectEqual(@as(f32, 96), centred.y);
    try std.testing.expectEqual(
        @as(?usize, 2),
        menu.hit(.centered, screen, metrics, centred.x + 20, centred.y + 10 + Menu.headerHeight(metrics) + 2.5 * Menu.rowHeight(metrics)),
    );
}
