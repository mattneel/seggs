pub const Color = [4]f32;
pub fn rgb(value: u24) Color {
    return .{
        @as(f32, @floatFromInt((value >> 16) & 255)) / 255,
        @as(f32, @floatFromInt((value >> 8) & 255)) / 255,
        @as(f32, @floatFromInt(value & 255)) / 255,
        1,
    };
}
pub const background = rgb(0x101216);
pub const panel = rgb(0x16191f);
pub const raised = rgb(0x1d222b);
pub const selected = rgb(0x263b36);
pub const border = rgb(0x2b3039);
pub const text = rgb(0xdce2ed);
pub const muted = rgb(0x8c97aa);
pub const accent = rgb(0x8ee8b4);
pub const purple = rgb(0xc6a0f6);
pub const amber = rgb(0xf5c57d);
pub const red = rgb(0xf38ba8);
pub const blue = rgb(0x91b9ff);
