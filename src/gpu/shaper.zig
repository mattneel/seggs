const std = @import("std");
const zignal = @import("zignal");
const files = @import("../platform/files.zig");
const Allocator = std.mem.Allocator;

/// Glyph selection for a text run, using zignal's TrueType parser. The shaper
/// decides which glyph index to draw; the atlas rasterizes that index and
/// supplies the advances, so selection stays independent of rasterization.
pub const Shaper = struct {
    allocator: Allocator,
    /// The font borrows these bytes, so they outlive it.
    data: []u8,
    font: zignal.VectorFont,

    pub fn init(a: Allocator, path: []const u8) !Shaper {
        const data = try files.read(a, path, 64 * 1024 * 1024);
        errdefer a.free(data);
        const font = try zignal.VectorFont.loadFromBytes(data);
        return .{ .allocator = a, .data = data, .font = font };
    }

    pub fn deinit(self: *Shaper) void {
        self.allocator.free(self.data);
    }

    /// Glyph index for a codepoint; 0 is `.notdef`, meaning the face has none.
    pub fn glyphIndex(self: *const Shaper, cp: u21) u16 {
        return self.font.glyphIndex(cp);
    }
};
