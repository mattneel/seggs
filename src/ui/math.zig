//! Display math: the TeX engine's drawing, landing in the editor's renderer.
//!
//! The engine lays a formula out and calls back for every mark it makes. What
//! arrives here is not TeX-specific - a colour, a line, a filled box, and a run
//! of text - which is why this layer is the beginning of the drawing primitives
//! rather than a special case for mathematics.
//!
//! Two properties of the engine's drawing shape the code below:
//!
//!   * It composes transforms by translating and scaling, and the scale is
//!     almost always 1 because the formula was laid out at the size it is drawn
//!     at. Positions are therefore transformed exactly, through the affine, and
//!     text is drawn at the atlas's size rather than a scaled one: the atlas
//!     holds one rasterization per glyph, and asking it for a second size is
//!     work this has not needed yet.
//!   * Colours arrive as ARGB with the alpha in the high byte, which is the
//!     engine's convention and not the renderer's.

const std = @import("std");
const renderer_mod = @import("../gpu/renderer.zig");
const theme = @import("theme.zig");

const Renderer = renderer_mod.Renderer;
const Color = theme.Color;
// The translate-c module is the header's declarations directly, so the C
// surface is reached under the name it was imported by.
const c = @import("microtex");

/// The engine is loaded once and stays loaded. `init` parses its resource
/// tables from XML, which its own documentation warns is slow, so it happens on
/// the first formula rather than at startup and never on the drawing path.
var ready: bool = false;

pub fn isReady() bool {
    return ready;
}

/// Load the engine's resources from `res_dir`. Returns false when the directory
/// cannot be read, and the caller then shows formula source instead of a
/// rendering - the editor stays usable without mathematics.
pub fn init(res_dir: [*:0]const u8) bool {
    if (ready) return true;
    if (!c.seggs_tex_init(res_dir)) return false;
    ready = true;
    return true;
}

/// Where the engine's resources are.
///
/// The tables and font data live in the dependency tree rather than beside the
/// binary, because they are fetched rather than installed: an installed layout
/// is a separate question the packaging does not answer yet. Both places are
/// tried so an installed build works once it does, and the directory is only
/// looked for when the first formula appears.
pub fn resourceDir() [*:0]const u8 {
    return ".deps/MicroTex/res";
}

pub fn deinit() void {
    var it = cache.valueIterator();
    while (it.next()) |formula| formula.deinit();
    cache.deinit(cache_allocator);
    cache = .empty;
    if (!ready) return;
    c.seggs_tex_release();
    ready = false;
}

/// A laid-out formula, owned until `deinit` releases it.
pub const Formula = struct {
    handle: *anyopaque,

    pub fn deinit(self: Formula) void {
        c.seggs_tex_free(self.handle);
    }

    /// Width, height above the baseline, and depth below it. All three are
    /// needed to place a formula in a row of text: the height and depth are what
    /// keep the row from overlapping its neighbours.
    pub fn measure(self: Formula) Metrics {
        var width: f32 = 0;
        var height: f32 = 0;
        var depth: f32 = 0;
        c.seggs_tex_measure(self.handle, &width, &height, &depth);
        return .{ .width = width, .height = height, .depth = depth };
    }
};

pub const Metrics = struct {
    width: f32,
    height: f32,
    depth: f32,
};

/// Lay out `tex`, a run of codepoints rather than bytes, because mathematics is
/// not ASCII. `width` is the layout width in points, or 0 for a single line at
/// the formula's natural width. Returns null when the engine rejects the input,
/// having printed its reason to stderr - which keeps it out of the protocol
/// stream on stdout.
pub fn parse(tex: []const u32, width: i32, text_size: f32, line_space: f32, fg: Color) ?Formula {
    if (!ready or tex.len == 0) return null;
    const handle = c.seggs_tex_parse(tex.ptr, tex.len, width, text_size, line_space, toArgb(fg));
    if (handle == null) return null;
    return .{ .handle = handle.? };
}

/// Formulas already laid out, by the text they were laid out from.
///
/// A layout is expensive - the engine resolves macros, builds a box tree and
/// positions every atom - and the transcript rebuilds its rows on every frame,
/// so a parse per frame would be unusable. The key is the formula itself,
/// because that is the only thing the layout depends on. Formulas are released
/// with the engine, which bounds this by the number of distinct formulas a
/// session contains.
var cache: std.AutoHashMapUnmanaged(u64, Formula) = .empty;

/// The cache outlives every frame, so it may not be built out of one.
///
/// Callers lay the transcript out against a frame arena, which is reset when the
/// frame ends. A map built on that memory holds pointers into it, and the next
/// frame looks a key up in storage that has already been freed - so this uses an
/// allocator with the process's lifetime instead. The engine's own state has the
/// same lifetime, and a layout is meaningful for exactly as long as its
/// resources are loaded.
const cache_allocator = std.heap.c_allocator;

/// Lay out a formula, or return the one already laid out for this text.
pub fn parseCached(tex: []const u32, text_size: f32, line_space: f32, fg: Color) ?Formula {
    const key = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(tex));
    if (cache.size != 0) {
        if (cache.get(key)) |held| return held;
    }
    const parsed = parse(tex, 0, text_size, line_space, fg) orelse return null;
    cache.put(cache_allocator, key, parsed) catch return parsed;
    return parsed;
}

/// What a callback needs to draw: the renderer, and the colour the engine last
/// set. The engine sets a colour and then draws with it, so the colour is state
/// that outlives a single call.
const Canvas = struct {
    renderer: *Renderer,
    color: Color,
};

/// Draw `formula` with its top-left corner at (x, y).
///
/// The callbacks are a static table: they are handed to C, so they cannot carry
/// state of their own, and the renderer arrives through the engine's own
/// context pointer.
pub fn draw(formula: Formula, renderer: *Renderer, x: f32, y: f32, fg: Color) void {
    var canvas = Canvas{ .renderer = renderer, .color = fg };
    const callbacks = c.seggs_tex_callbacks{
        .ctx = &canvas,
        .set_color = setColor,
        .fill_rect = fillRect,
        .draw_line = drawLine,
        .draw_text = drawText,
        .text_width = textWidth,
    };
    c.seggs_tex_draw(formula.handle, x, y, &callbacks);
}

fn canvasOf(ctx: ?*anyopaque) *Canvas {
    return @ptrCast(@alignCast(ctx.?));
}

fn setColor(ctx: ?*anyopaque, argb: u32) callconv(.c) void {
    canvasOf(ctx).color = fromArgb(argb);
}

fn fillRect(ctx: ?*anyopaque, x: f32, y: f32, w: f32, h: f32, t: [*c]const c.seggs_tex_transform) callconv(.c) void {
    const canvas = canvasOf(ctx);
    // A formula is laid out in points and drawn in pixels one to one, so a fill
    // is a rectangle under an affine that is usually the identity. It goes
    // through the transform anyway: leaving it out would be right almost always
    // and wrong in a way that would be hard to find.
    canvas.renderer.rectTransformed(x, y, w, h, transformOf(t), canvas.color) catch {};
}

fn drawLine(ctx: ?*anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, width: f32, t: [*c]const c.seggs_tex_transform) callconv(.c) void {
    const canvas = canvasOf(ctx);
    const m = transformOf(t);
    const a = applyAffine(m, x1, y1);
    const b = applyAffine(m, x2, y2);
    // The stroke width is scaled by the transform's own scale, so a formula
    // drawn at half size has half-width rules.
    const scale = @sqrt(@abs(m[0] * m[3] - m[1] * m[2]));
    canvas.renderer.line(a[0], a[1], b[0], b[1], width * scale, canvas.color) catch {};
}

fn drawText(ctx: ?*anyopaque, cps: [*c]const u32, count: usize, x: f32, y: f32, size: f32, style: i32, t: [*c]const c.seggs_tex_transform) callconv(.c) void {
    _ = size;
    _ = style;
    const canvas = canvasOf(ctx);
    const m = transformOf(t);
    const at = applyAffine(m, x, y);
    // The engine's y is the baseline, and so is the renderer's glyph origin, so
    // the two agree without adjustment - which is the reason to draw text
    // through the same path the terminal does.
    var pen = at[0];
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const cp = cps[i];
        if (cp > 0x10FFFF) continue;
        pen += canvas.renderer.glyphAt(pen, at[1], @intCast(cp), canvas.color) catch break;
    }
}

/// The engine asks how wide a run it is about to draw, so it can lay out around
/// it. Reporting the atlas's advance keeps the layout and the drawing in
/// agreement, which is the property that matters here.
fn textWidth(ctx: ?*anyopaque, cps: [*c]const u32, count: usize, size: f32, style: i32) callconv(.c) f32 {
    _ = size;
    _ = style;
    const canvas = canvasOf(ctx);
    var total: f32 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const cp = cps[i];
        if (cp > 0x10FFFF) continue;
        total += canvas.renderer.glyphAdvance(@intCast(cp));
    }
    return total;
}

fn transformOf(t: [*c]const c.seggs_tex_transform) [6]f32 {
    if (t == null) return .{ 1, 0, 0, 1, 0, 0 };
    return t.*.m;
}

fn applyAffine(m: [6]f32, x: f32, y: f32) [2]f32 {
    return .{ m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] };
}

/// The engine's colour is ARGB with the alpha in the high byte; the renderer's
/// is four linear floats in red, green, blue, alpha order. Nothing else in the
/// editor uses ARGB, so the conversion lives here rather than in the theme.
fn fromArgb(argb: u32) Color {
    return .{
        @as(f32, @floatFromInt((argb >> 16) & 0xff)) / 255,
        @as(f32, @floatFromInt((argb >> 8) & 0xff)) / 255,
        @as(f32, @floatFromInt(argb & 0xff)) / 255,
        @as(f32, @floatFromInt((argb >> 24) & 0xff)) / 255,
    };
}

fn toArgb(color: Color) u32 {
    const r: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0, 1) * 255));
    const g: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0, 1) * 255));
    const b: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0, 1) * 255));
    const a: u32 = @intFromFloat(@round(std.math.clamp(color[3], 0, 1) * 255));
    return (a << 24) | (r << 16) | (g << 8) | b;
}
