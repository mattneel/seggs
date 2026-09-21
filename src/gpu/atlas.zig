const std = @import("std");
const c = @import("native");
const Packer = @import("packer.zig").Packer;

/// Dynamic glyph atlas. Glyphs are rasterized from the system font on first
/// use and packed into one texture, so coverage follows the font rather than a
/// fixed codepoint table. No font file is bundled or redistributed.
///
/// The atlas is a cache: when it fills, a codepoint reuses the placeholder
/// glyph instead of failing the frame, and `missing` records that it happened.
pub const Atlas = struct {
    pub const width = 1024;
    pub const height = 1024;
    /// Keeps bilinear sampling from bleeding between neighbours.
    pub const padding = 1;

    /// Center of the reserved white texel, which solid quads sample.
    pub const solid_u: f32 = 0.5 / @as(f32, width);
    pub const solid_v: f32 = 0.5 / @as(f32, height);

    /// The reserved texel has to stay opaque white or every solid rectangle in
    /// the interface disappears, which no glyph test would notice.
    fn self_test(surface: *c.SDL_Surface) void {
        var red: u8 = 0;
        var green: u8 = 0;
        var blue: u8 = 0;
        var alpha: u8 = 0;
        if (!c.SDL_ReadSurfacePixel(surface, 0, 0, &red, &green, &blue, &alpha)) return;
        std.debug.assert(red == 255 and green == 255 and blue == 255 and alpha == 255);
    }

    pub const Glyph = struct {
        x: f32 = 0,
        y: f32 = 0,
        w: f32 = 0,
        h: f32 = 0,
        advance: f32 = 0,
        /// Ink offsets from the pen and the baseline, in draw units. A
        /// rasterized glyph is cropped to its ink, so where it belongs cannot be
        /// read from the bitmap: a period sits on the baseline while a capital
        /// starts at the cap height, and both are the same distance from the pen.
        offset_x: f32 = 0,
        offset_y: f32 = 0,
    };

    /// Ink metrics at the rasterizing size, with the baseline as the origin:
    /// `maxy` is the height of the ink above it, `miny` the depth below.
    const Metrics = struct { minx: c_int, maxy: c_int, advance: c_int };

    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    font: *c.TTF_Font,
    texture: *c.SDL_GPUTexture,
    transfer: *c.SDL_GPUTransferBuffer,
    surface: *c.SDL_Surface,
    packer: Packer,
    /// Keyed by font glyph index: shaping decides which glyph, the atlas only
    /// rasterizes and caches it.
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,
    /// Glyph index used when the atlas is full, set by the renderer.
    placeholder_id: u32 = 0,
    /// Fallback faces SDL_ttf consults when the primary face has no glyph.
    /// They stay open for the atlas's lifetime.
    fallbacks: std.ArrayList(*c.TTF_Font) = .empty,
    /// Codepoint keyed, because a glyph index only means something within one
    /// font: the primary and a fallback number their glyphs independently.
    fallback_glyphs: std.AutoHashMapUnmanaged(u21, Glyph) = .empty,
    dirty: bool = false,
    /// Codepoints that fell back to the placeholder glyph.
    missing: usize = 0,
    /// Nominal monospace advance, used for tab stops.
    /// The display's pixels per point, kept because the fallback faces are
    /// rasterised at the same density as the primary one.
    scale: f32,
    advance: f32,
    line_height: f32,
    /// Distance from the top of a line to its baseline, in draw units.
    ascent: f32,

    /// The size the interface measures in, in points.
    pub const base: f32 = 16;

    /// The face is rasterised at twice the size the interface measures in, so
    /// glyphs stay sharp when they are drawn at their measured size.
    pub const oversample: f32 = 2;

    /// `scale` is the display's pixels per point. The face is rasterised at
    /// `base * oversample * scale`, so a high-density display gets a finer
    /// face rather than a stretched one, while every metric below is converted
    /// back into points: the layout is the same on every display and only the
    /// pixels differ.
    pub fn init(a: std.mem.Allocator, device: *c.SDL_GPUDevice, font_path: [*:0]const u8, scale: f32) !Atlas {
        const raster: f32 = @round(base * oversample * scale);
        const font = c.TTF_OpenFont(font_path, raster) orelse return error.FontOpen;
        errdefer c.TTF_CloseFont(font);
        var advance: c_int = 0;
        if (!c.TTF_GetGlyphMetrics(font, 'M', null, null, null, null, &advance)) return error.FontMetrics;
        const surface = c.SDL_CreateSurface(width, height, c.SDL_PIXELFORMAT_RGBA32) orelse return error.AtlasSurface;
        errdefer c.SDL_DestroySurface(surface);
        _ = c.SDL_FillSurfaceRect(surface, null, c.SDL_MapSurfaceRGBA(surface, 0, 0, 0, 0));
        // One opaque texel that solid quads sample. Packing starts one pixel in,
        // so this corner is never part of a glyph and a rectangle does not have
        // to borrow a pixel from whichever glyph happened to be packed first.
        if (!c.SDL_WriteSurfacePixel(surface, 0, 0, 255, 255, 255, 255)) return error.AtlasSurface;
        self_test(surface);
        var texture_info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        texture_info.type = c.SDL_GPU_TEXTURETYPE_2D;
        texture_info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        texture_info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        texture_info.width = width;
        texture_info.height = height;
        texture_info.layer_count_or_depth = 1;
        texture_info.num_levels = 1;
        const texture = c.SDL_CreateGPUTexture(device, &texture_info) orelse return error.AtlasTexture;
        errdefer c.SDL_ReleaseGPUTexture(device, texture);
        var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
        transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        transfer_info.size = width * height * 4;
        const transfer = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse return error.AtlasTransfer;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        var atlas: Atlas = .{
            .allocator = a,
            .device = device,
            .font = font,
            .texture = texture,
            .transfer = transfer,
            .surface = surface,
            .packer = Packer.init(width, height),
            .scale = scale,
            // In device pixels: the face was rasterised larger by the same
            // factor, so dividing the oversample back out leaves metrics that
            // grew with the display. A denser screen gets the same interface
            // drawn larger and sharper, not the same number of smaller points.
            .advance = @as(f32, @floatFromInt(advance)) / oversample,
            .line_height = @max(22 * scale, @as(f32, @floatFromInt(c.TTF_GetFontLineSkip(font))) / oversample),
            .ascent = @as(f32, @floatFromInt(c.TTF_GetFontAscent(font))) / oversample,
        };
        errdefer atlas.glyphs.deinit(a);
        return atlas;
    }

    pub fn deinit(self: *Atlas) void {
        for (self.fallbacks.items) |fallback| c.TTF_CloseFont(fallback);
        self.fallbacks.deinit(self.allocator);
        self.fallback_glyphs.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        c.SDL_DestroySurface(self.surface);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.transfer);
        c.SDL_ReleaseGPUTexture(self.device, self.texture);
        c.TTF_CloseFont(self.font);
    }

    /// Number of glyphs packed so far.
    pub fn glyphCount(self: *const Atlas) usize {
        return self.packer.count;
    }

    /// Glyph for a font glyph index, rasterized and packed on first use. When
    /// the atlas is full the placeholder stands in and `missing` counts it.
    ///
    /// The codepoint is needed as well as the index because the ink metrics come
    /// from a codepoint query, which is also what walks the fallback chain, so
    /// the placement and the rasterized bitmap come from the same face.
    pub fn glyphFor(self: *Atlas, cp: u21, id: u32) !Glyph {
        if (self.glyphs.get(id)) |glyph| return glyph;
        const blank: Glyph = .{ .advance = self.advance };
        const glyph = self.rasterize(id, self.metricsOf(cp)) catch |err| switch (err) {
            error.AtlasFull => blk: {
                self.missing += 1;
                break :blk self.glyphs.get(self.placeholder_id) orelse blank;
            },
            else => return err,
        };
        try self.glyphs.put(self.allocator, id, glyph);
        return glyph;
    }

    /// Advance for a codepoint, in draw units. `TTF_GetGlyphMetrics` takes a
    /// codepoint, so this is separate from the by-index glyph lookup.
    pub fn advanceFor(self: *Atlas, cp: u21) f32 {
        const metrics = self.metricsOf(cp) orelse return self.advance;
        return @as(f32, @floatFromInt(metrics.advance)) / 2;
    }

    /// Ink metrics for a codepoint, resolved through the fallback chain, or null
    /// when no face in the chain has it.
    fn metricsOf(self: *Atlas, cp: u21) ?Metrics {
        var minx: c_int = 0;
        var maxx: c_int = 0;
        var miny: c_int = 0;
        var maxy: c_int = 0;
        var advance: c_int = 0;
        if (!c.TTF_GetGlyphMetrics(self.font, cp, &minx, &maxx, &miny, &maxy, &advance)) return null;
        return .{ .minx = minx, .maxy = maxy, .advance = advance };
    }

    /// Where a glyph's ink sits relative to the pen and the baseline, in draw
    /// units. The rasterizer measures upward from the baseline, the renderer
    /// downward from the top of the line.
    const Offset = struct { x: f32, y: f32 };

    fn inkOffsets(metrics: Metrics) Offset {
        return .{
            .x = @as(f32, @floatFromInt(metrics.minx)) / 2,
            .y = -@as(f32, @floatFromInt(metrics.maxy)) / 2,
        };
    }

    /// Glyph for a codepoint the primary face lacks, resolved through the
    /// fallback chain. Falls back to the placeholder when no registered face
    /// can draw it, so an unsupported script stays visible.
    pub fn fallbackGlyph(self: *Atlas, cp: u21) !Glyph {
        if (self.fallback_glyphs.get(cp)) |glyph| return glyph;
        const blank: Glyph = .{ .advance = self.advance };
        const glyph = self.rasterizeFallback(cp, self.metricsOf(cp)) catch |err| switch (err) {
            error.GlyphImage, error.AtlasFull => blk: {
                self.missing += 1;
                break :blk self.glyphs.get(self.placeholder_id) orelse blank;
            },
            else => return err,
        };
        try self.fallback_glyphs.put(self.allocator, cp, glyph);
        return glyph;
    }

    /// Register a fallback face. SDL_ttf consults the chain when the primary
    /// face has no glyph, which is how `fallbackGlyph` rasterizes a codepoint
    /// the shaper could not resolve.
    pub fn addFallback(self: *Atlas, path: [*:0]const u8) !void {
        const fallback = c.TTF_OpenFont(path, @round(base * oversample * self.scale)) orelse return error.FontOpen;
        errdefer c.TTF_CloseFont(fallback);
        if (!c.TTF_AddFallbackFont(self.font, fallback)) return error.FallbackRejected;
        try self.fallbacks.append(self.allocator, fallback);
    }

    /// Number of fallback faces registered.
    pub fn fallbackCount(self: *const Atlas) usize {
        return self.fallbacks.items.len;
    }

    fn rasterize(self: *Atlas, id: u32, metrics: ?Metrics) !Glyph {
        const image = c.TTF_GetGlyphImageForIndex(self.font, id, null) orelse return error.GlyphImage;
        defer c.SDL_DestroySurface(image);
        const slot = try self.packImage(image);
        const offsets: Offset = if (metrics) |m| inkOffsets(m) else .{ .x = 0, .y = 0 };
        return .{ .x = slot.x, .y = slot.y, .w = slot.w, .h = slot.h, .advance = self.advance, .offset_x = offsets.x, .offset_y = offsets.y };
    }

    /// Metrics and outline both walk the fallback chain, so this rasterizes
    /// whatever face can actually draw the codepoint.
    fn rasterizeFallback(self: *Atlas, cp: u21, metrics: ?Metrics) !Glyph {
        const image = c.TTF_GetGlyphImage(self.font, cp, null) orelse return error.GlyphImage;
        defer c.SDL_DestroySurface(image);
        const slot = try self.packImage(image);
        const advance = if (metrics) |m| @as(f32, @floatFromInt(m.advance)) / 2 else self.advance;
        const offsets: Offset = if (metrics) |m| inkOffsets(m) else .{ .x = 0, .y = 0 };
        return .{ .x = slot.x, .y = slot.y, .w = slot.w, .h = slot.h, .advance = advance, .offset_x = offsets.x, .offset_y = offsets.y };
    }

    /// Blit one glyph image into the atlas and record where it landed.
    fn packImage(self: *Atlas, image: *c.SDL_Surface) !Glyph {
        const w: u32 = @intCast(image.*.w);
        const h: u32 = @intCast(image.*.h);
        const slot = self.packer.allocate(w, h, padding) orelse return error.AtlasFull;
        const dst: c.SDL_Rect = .{ .x = @intCast(slot.x), .y = @intCast(slot.y), .w = image.*.w, .h = image.*.h };
        // Copy straight alpha: blending during construction darkens edges.
        _ = c.SDL_SetSurfaceBlendMode(image, c.SDL_BLENDMODE_NONE);
        if (!c.SDL_BlitSurface(image, null, self.surface, &dst)) return error.GlyphBlit;
        self.markDirty();
        return .{ .x = @floatFromInt(slot.x), .y = @floatFromInt(slot.y), .w = @floatFromInt(w), .h = @floatFromInt(h) };
    }

    fn markDirty(self: *Atlas) void {
        self.dirty = true;
    }

    /// Upload glyphs rasterized since the last flush. Safe to call every frame;
    /// it returns immediately when nothing changed.
    ///
    /// The copy covers the whole texture rather than just the new glyphs. A
    /// partial copy of an optimally tiled image is only allowed to the extent
    /// the queue family's image transfer granularity permits, and drivers built
    /// on APIs with their own alignment rules, such as the D3D12-based Dozen,
    /// report no granularity and then reject the copy. The atlas only uploads
    /// when a glyph was added, so the extra bytes are rare rather than per-frame.
    pub fn flush(self: *Atlas) !void {
        if (!self.dirty) return;
        const command = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.GpuCommand;
        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.device, self.transfer, true) orelse {
            _ = c.SDL_CancelGPUCommandBuffer(command);
            return error.GpuMap;
        });
        const pixels: [*]const u8 = @ptrCast(self.surface.*.pixels.?);
        const pitch: usize = @intCast(self.surface.*.pitch);
        for (0..@as(usize, height)) |row| {
            const source = row * pitch;
            @memcpy(mapped[row * width * 4 ..][0 .. width * 4], pixels[source..][0 .. width * 4]);
        }
        c.SDL_UnmapGPUTransferBuffer(self.device, self.transfer);
        const copy = c.SDL_BeginGPUCopyPass(command) orelse {
            _ = c.SDL_CancelGPUCommandBuffer(command);
            return error.GpuCopyPass;
        };
        var from = std.mem.zeroes(c.SDL_GPUTextureTransferInfo);
        from.transfer_buffer = self.transfer;
        var region = std.mem.zeroes(c.SDL_GPUTextureRegion);
        region.texture = self.texture;
        region.x = 0;
        region.y = 0;
        region.w = width;
        region.h = height;
        region.d = 1;
        c.SDL_UploadToGPUTexture(copy, &from, &region, false);
        c.SDL_EndGPUCopyPass(copy);
        if (!c.SDL_SubmitGPUCommandBuffer(command)) return error.GpuSubmit;
        self.dirty = false;
    }
};
