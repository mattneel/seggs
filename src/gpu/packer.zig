const std = @import("std");

/// Row-based rectangle packer for a fixed-size atlas. Rectangles fill a row
/// left to right; a full row starts the next one below the tallest rectangle
/// seen in it. Pure logic, so the packing rules are testable without a GPU.
pub const Packer = struct {
    width: u32,
    height: u32,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    row_height: u32 = 0,
    /// Number of rectangles handed out. The atlas reports this as coverage.
    count: usize = 0,

    pub const Slot = struct { x: u32, y: u32 };

    pub fn init(width: u32, height: u32) Packer {
        return .{ .width = width, .height = height };
    }

    /// Reserve `w` by `h` with `padding` on each side. Returns null when the
    /// rectangle cannot fit in what remains of the atlas.
    pub fn allocate(self: *Packer, w: u32, h: u32, padding: u32) ?Slot {
        const cell_w = w + padding * 2;
        const cell_h = h + padding * 2;
        if (cell_w > self.width or cell_h > self.height) return null;
        if (self.cursor_x + cell_w > self.width) {
            self.cursor_y += self.row_height;
            self.cursor_x = 0;
            self.row_height = 0;
        }
        if (self.cursor_y + cell_h > self.height) return null;
        const slot = Slot{ .x = self.cursor_x + padding, .y = self.cursor_y + padding };
        self.cursor_x += cell_w;
        self.row_height = @max(self.row_height, cell_h);
        self.count += 1;
        return slot;
    }
};

test "packer places glyphs inside the atlas without overlap" {
    var packer = Packer.init(64, 64);
    var placed: [8]Packer.Slot = undefined;
    var total: usize = 0;
    while (total < placed.len) : (total += 1) {
        placed[total] = packer.allocate(10, 10, 1) orelse break;
    }
    try std.testing.expect(total > 1);
    for (placed[0..total], 0..) |slot, index| {
        try std.testing.expect(slot.x + 10 <= 64);
        try std.testing.expect(slot.y + 10 <= 64);
        for (placed[0..index]) |other| {
            const disjoint = slot.x + 10 <= other.x or other.x + 10 <= slot.x or
                slot.y + 10 <= other.y or other.y + 10 <= slot.y;
            try std.testing.expect(disjoint);
        }
    }
}

test "packer rejects what cannot fit and reports exhaustion" {
    var packer = Packer.init(32, 32);
    // Wider or taller than the atlas is rejected outright.
    try std.testing.expect(packer.allocate(33, 4, 0) == null);
    try std.testing.expect(packer.allocate(4, 33, 0) == null);
    // Padding counts against the limit too.
    try std.testing.expect(packer.allocate(32, 4, 1) == null);
    var allocated: usize = 0;
    while (packer.allocate(9, 9, 1)) |_| allocated += 1;
    try std.testing.expect(allocated > 0);
    try std.testing.expectEqual(allocated, packer.count);
}
