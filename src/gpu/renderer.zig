const std = @import("std");

/// The most pixels every kept picture may add up to: 8 MP, or 32 MB once they
/// are RGBA. This is the picture space's budget rather than a bound on one
/// image - `gpu/image.zig` bounds the decode at half of this - and it is
/// deliberately twice the largest image, so a full-size one never has to empty
/// the space to fit.
pub const max_picture_pixels: usize = 8 * 1024 * 1024;

/// The most pictures the renderer remembers. Pixels are what cost and the pixel
/// budget is what bounds them; this bounds the entries, so a session that
/// scrolls past hundreds of pictures cannot grow the map without end.
pub const max_pictures: usize = 64;

var diag_count: usize = 0;
var shear_log: usize = 0;
const builtin = @import("builtin");
const c = @import("native");
const shaders = @import("shaders");
const Atlas = @import("atlas.zig").Atlas;
const Shaper = @import("shaper.zig").Shaper;
const image = @import("../gpu/image.zig");
const Rect = @import("../ui/layout.zig").Rect;
const Color = @import("../ui/theme.zig").Color;

/// A point placed by a 2D affine:
///
///     x' = m[0]*x + m[2]*y + m[4]
///     y' = m[1]*x + m[3]*y + m[5]
///
/// The order is the drawing layer's, which is the order the TeX engine composes
/// its transforms in, so a matrix crosses that boundary without rearrangement.
fn affinePoint(m: [6]f32, x: f32, y: f32) [2]f32 {
    return .{ m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] };
}
const text_util = @import("../core/text.zig");
const zignal = @import("zignal");

pub const Renderer = struct {
    const Vertex = extern struct { position: [2]f32, uv: [2]f32, color: Color };
    const max_vertices = 262_144;

    /// One run of vertices drawn with one texture, in the order they were
    /// appended. A frame is a single segment - and so a single draw call - for
    /// as long as everything on it samples the glyph atlas. A picture is not in
    /// the atlas, so drawing one starts a second segment, and the frame becomes
    /// a short sequence of draws with a texture rebound between them. The order
    /// is the order the rows were drawn in, which is what keeps a picture behind
    /// the rows that come after it exactly as it was before this existed.
    const Segment = struct { texture: *c.SDL_GPUTexture, first: usize, count: usize };

    /// A decoded picture that is on screen: the texture it lives in, and the
    /// size the decoder found.
    pub const Picture = struct { texture: *c.SDL_GPUTexture, width: u32, height: u32 };

    /// What the picture space did with a record: the texture to draw, or the
    /// reason there is nothing to draw. A failure to allocate is not in here -
    /// that is the machine's problem and not the image's, so it is an error.
    pub const Drawn = union(enum) { picture: Picture, refused: image.Refusal };

    /// What the space remembers about one handle: the picture, or why there is
    /// none, and the frame it was last asked for.
    const Entry = struct {
        state: Drawn,
        last: u64,
    };

    /// One texture per picture, rather than one packed surface for all of them.
    ///
    /// The glyph atlas was the obvious candidate and is the wrong one: it is
    /// 1024×1024 and holds an alphabet, one picture of any size at all would
    /// take the room a run of text needs, and the atlas answers a full surface
    /// with the placeholder glyph - so the failure would land on every piece of
    /// text on screen rather than on the picture. A picture also has no business
    /// being a cache entry: it is decoded once and drawn scaled, so its own
    /// pixels are the whole of what it needs.
    pictures: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    /// The pixels every kept picture adds up to, which is what the space bounds:
    /// what costs is the bitmaps, not the number of entries.
    picture_pixels: usize = 0,
    /// The frame the space is drawing, so that what is evicted is what a reader
    /// has stopped looking at.
    frame: u64 = 0,
    /// Every quad the frame is made of, grouped by the texture it samples.
    segments: std.ArrayList(Segment) = .empty,
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    vertex_buffer: *c.SDL_GPUBuffer,
    transfer: *c.SDL_GPUTransferBuffer,
    sampler: *c.SDL_GPUSampler,
    atlas: Atlas,
    shaper: Shaper,
    vertices: std.ArrayList(Vertex) = .empty,
    width: f32 = 1,
    height: f32 = 1,
    clip: Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },

    pub fn init(a: std.mem.Allocator, window: *c.SDL_Window, font: [*:0]const u8, scale: f32) !Renderer {
        const metal = builtin.os.tag == .macos;
        const format = if (metal) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV;
        const device = c.SDL_CreateGPUDevice(format, builtin.mode == .debug, null) orelse return error.GpuDevice;
        errdefer c.SDL_DestroyGPUDevice(device);
        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) return error.GpuClaim;
        errdefer c.SDL_ReleaseWindowFromGPUDevice(device, window);
        _ = c.SDL_SetGPUSwapchainParameters(device, window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, c.SDL_GPU_PRESENTMODE_VSYNC);
        const vertex = try createShader(device, format, c.SDL_GPU_SHADERSTAGE_VERTEX);
        defer c.SDL_ReleaseGPUShader(device, vertex);
        const fragment = try createShader(device, format, c.SDL_GPU_SHADERSTAGE_FRAGMENT);
        defer c.SDL_ReleaseGPUShader(device, fragment);
        const buffers = [_]c.SDL_GPUVertexBufferDescription{.{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 }};
        const attributes = [_]c.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "position") },
            .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "uv") },
            .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(Vertex, "color") },
        };
        var target = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
        target.format = c.SDL_GetGPUSwapchainTextureFormat(device, window);
        target.blend_state.enable_blend = true;
        target.blend_state.src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA;
        target.blend_state.dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        target.blend_state.color_blend_op = c.SDL_GPU_BLENDOP_ADD;
        target.blend_state.src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE;
        target.blend_state.dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        target.blend_state.alpha_blend_op = c.SDL_GPU_BLENDOP_ADD;
        var pipeline_info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
        pipeline_info.vertex_shader = vertex;
        pipeline_info.fragment_shader = fragment;
        pipeline_info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        pipeline_info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
        pipeline_info.rasterizer_state.cull_mode = c.SDL_GPU_CULLMODE_NONE;
        pipeline_info.multisample_state.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
        pipeline_info.vertex_input_state = .{ .vertex_buffer_descriptions = &buffers, .num_vertex_buffers = buffers.len, .vertex_attributes = &attributes, .num_vertex_attributes = attributes.len };
        pipeline_info.target_info.color_target_descriptions = &target;
        pipeline_info.target_info.num_color_targets = 1;
        const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_info) orelse return error.GpuPipeline;
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
        var buffer_info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
        buffer_info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX;
        buffer_info.size = max_vertices * @sizeOf(Vertex);
        const vertex_buffer = c.SDL_CreateGPUBuffer(device, &buffer_info) orelse return error.GpuBuffer;
        errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);
        var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
        transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        transfer_info.size = buffer_info.size;
        const transfer = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse return error.GpuTransfer;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        var sampler_info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
        sampler_info.min_filter = c.SDL_GPU_FILTER_LINEAR;
        sampler_info.mag_filter = c.SDL_GPU_FILTER_LINEAR;
        sampler_info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
        sampler_info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        sampler_info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        sampler_info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        const sampler = c.SDL_CreateGPUSampler(device, &sampler_info) orelse return error.GpuSampler;
        errdefer c.SDL_ReleaseGPUSampler(device, sampler);
        var atlas = try Atlas.init(a, device, font, scale);
        var shaper = try Shaper.init(a, std.mem.span(font));
        errdefer shaper.deinit();
        atlas.placeholder_id = shaper.glyphIndex('?');
        // Warm printable ASCII so the first frames do not upload glyph by glyph.
        for (33..127) |codepoint| _ = try atlas.glyphFor(@intCast(codepoint), shaper.glyphIndex(@intCast(codepoint)));
        try atlas.flush();
        return .{ .allocator = a, .window = window, .device = device, .pipeline = pipeline, .vertex_buffer = vertex_buffer, .transfer = transfer, .sampler = sampler, .atlas = atlas, .shaper = shaper };
    }

    fn createShader(device: *c.SDL_GPUDevice, format: c.SDL_GPUShaderFormat, stage: c.SDL_GPUShaderStage) !*c.SDL_GPUShader {
        const vertex = stage == c.SDL_GPU_SHADERSTAGE_VERTEX;
        const metal = builtin.os.tag == .macos;
        const code = if (metal) shaders.metal else if (vertex) shaders.vertex_spv else shaders.fragment_spv;
        var info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
        info.code = code.ptr;
        info.code_size = code.len;
        info.entrypoint = if (metal) (if (vertex) "seggs_vertex" else "seggs_fragment") else "main";
        info.format = format;
        info.stage = stage;
        info.num_samplers = if (vertex) 0 else 1;
        return c.SDL_CreateGPUShader(device, &info) orelse error.GpuShader;
    }

    pub fn deinit(self: *Renderer) void {
        _ = c.SDL_WaitForGPUIdle(self.device);
        self.segments.deinit(self.allocator);
        self.releasePictures();
        self.pictures.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.shaper.deinit();
        self.atlas.deinit();
        c.SDL_ReleaseGPUSampler(self.device, self.sampler);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.transfer);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
    }

    pub fn begin(self: *Renderer, width: f32, height: f32) void {
        self.vertices.clearRetainingCapacity();
        self.segments.clearRetainingCapacity();
        self.frame += 1;
        self.width = @max(1, width);
        self.height = @max(1, height);
        self.clip = .{ .x = 0, .y = 0, .w = self.width, .h = self.height };
    }

    pub fn rect(self: *Renderer, bounds: Rect, color: Color) !void {
        try self.quad(bounds, .{ .x = Atlas.solid_u, .y = Atlas.solid_v, .w = 0, .h = 0 }, color);
    }

    /// Four arbitrary corners as two triangles, filled with a solid colour.
    ///
    /// Every other quad in this renderer is axis-aligned, because a terminal
    /// draws nothing that is not. A drawing layer is not, and a line, a rotated
    /// box, and a stroke all reduce to this one primitive, so this is where the
    /// rest of the drawing is built from. Corners are in screen coordinates, in
    /// the order top-left, top-right, bottom-right, bottom-left.
    pub fn quadCorners(self: *Renderer, corners: [4][2]f32, color: Color) !void {
        // A quad that falls wholly outside the clip contributes nothing, and
        // skipping it here keeps a formula scrolled out of its panel from
        // costing six vertices. The glyph path clips exactly; this one rejects
        // rather than clips, which is only visible when a shape straddles the
        // clip edge - a case the caller avoids by not drawing there.
        var min_x = corners[0][0];
        var max_x = min_x;
        var min_y = corners[0][1];
        var max_y = min_y;
        for (corners[1..]) |p| {
            min_x = @min(min_x, p[0]);
            max_x = @max(max_x, p[0]);
            min_y = @min(min_y, p[1]);
            max_y = @max(max_y, p[1]);
        }
        if (max_x <= self.clip.x or min_x >= self.clip.x + self.clip.w) return;
        if (max_y <= self.clip.y or min_y >= self.clip.y + self.clip.h) return;
        if (self.vertices.items.len + 6 > max_vertices) return error.FrameGeometryLimit;
        const uv = [2]f32{ Atlas.solid_u, Atlas.solid_v };
        const tl = self.screenVertex(corners[0], uv, color);
        const tr = self.screenVertex(corners[1], uv, color);
        const br = self.screenVertex(corners[2], uv, color);
        const bl = self.screenVertex(corners[3], uv, color);
        try self.openSegment(self.atlas.texture);
        try self.vertices.appendSlice(self.allocator, &.{ tl, bl, tr, tr, bl, br });
    }

    /// A line of the given width, as a quad spanning the two endpoints.
    ///
    /// A terminal never draws one, which is why the renderer had no line until
    /// the drawing layer wanted a fraction bar. Width is the full width of the
    /// stroke, centred on the segment; a hairline is a width of one.
    pub fn line(self: *Renderer, x1: f32, y1: f32, x2: f32, y2: f32, width: f32, color: Color) !void {
        const dx = x2 - x1;
        const dy = y2 - y1;
        const len = @sqrt(dx * dx + dy * dy);
        if (len <= 0) return;
        const half = @max(width, 1) * 0.5;
        // The perpendicular, scaled to half the stroke.
        const px = -dy / len * half;
        const py = dx / len * half;
        try self.quadCorners(.{
            .{ x1 + px, y1 + py },
            .{ x2 + px, y2 + py },
            .{ x2 - px, y2 - py },
            .{ x1 - px, y1 - py },
        }, color);
    }

    /// A filled rectangle placed by a 2D affine, so a drawing layer can scale
    /// and rotate what it fills. The corners are transformed here rather than in
    /// the shader: there is one transform per shape, not one per vertex.
    pub fn rectTransformed(self: *Renderer, x: f32, y: f32, w: f32, h: f32, m: [6]f32, color: Color) !void {
        if (w <= 0 or h <= 0) return;
        try self.quadCorners(.{
            affinePoint(m, x, y),
            affinePoint(m, x + w, y),
            affinePoint(m, x + w, y + h),
            affinePoint(m, x, y + h),
        }, color);
    }

    fn screenVertex(self: *const Renderer, p: [2]f32, uv: [2]f32, color: Color) Vertex {
        return .{
            .position = .{ p[0] / self.width * 2 - 1, 1 - p[1] / self.height * 2 },
            .uv = .{ uv[0], uv[1] },
            .color = color,
        };
    }

    /// The advance a codepoint would take, without drawing it. A drawing layer
    /// asks for a width before it decides where to put the ink; the terminal
    /// never does, because it moves the pen as it draws.
    pub fn glyphAdvance(self: *Renderer, cp: u21) f32 {
        return self.atlas.advanceFor(cp);
    }

    /// Draw one codepoint at pen `x` on the baseline `y`, and return the
    /// advance. The shaper picks the glyph from the primary face; when it has
    /// none, the atlas resolves the codepoint through the registered fallback
    /// chain.
    pub fn glyphAt(self: *Renderer, x: f32, y: f32, cp: u21, color: Color) !f32 {
        const index = self.shaper.glyphIndex(cp);
        if (index == 0) {
            const fallback = try self.atlas.fallbackGlyph(cp);
            try self.drawGlyph(x, y, fallback, color);
            return fallback.advance;
        }
        const glyph = try self.atlas.glyphFor(cp, index);
        try self.drawGlyph(x, y, glyph, color);
        return self.atlas.advanceFor(cp);
    }

    /// Register a face SDL_ttf consults when the primary face has no glyph.
    pub fn addFallbackFont(self: *Renderer, path: [*:0]const u8) !void {
        try self.atlas.addFallback(path);
    }

    pub fn fallbackFontCount(self: *const Renderer) usize {
        return self.atlas.fallbackCount();
    }

    /// `y` is the baseline: the packed bitmap holds only the glyph's ink, so the
    /// offsets the atlas measured are what put it back on the baseline rather
    /// than at the top of the line.
    fn drawGlyph(self: *Renderer, x: f32, y: f32, g: Atlas.Glyph, color: Color) !void {
        return self.drawGlyphSheared(x, y, g, color, 0);
    }

    fn drawGlyphSheared(self: *Renderer, x: f32, y: f32, g: Atlas.Glyph, color: Color, shear: f32) !void {
        if (@import("builtin").is_test) {} else if (y >= 640 and diag_count < 6) {
            diag_count += 1;
            std.log.info("glyph: at {d:.1},{d:.1} rect {d}x{d} off {d},{d} color {d:.2},{d:.2},{d:.2} clip {d:.0},{d:.0} {d:.0}x{d:.0}", .{ x, y, g.w, g.h, g.offset_x, g.offset_y, color[0], color[1], color[2], self.clip.x, self.clip.y, self.clip.w, self.clip.h });
        }
        if (g.w <= 0 or g.h <= 0) return;
        try self.quadSheared(.{ .x = x + g.offset_x, .y = y + g.offset_y, .w = g.w / 2, .h = g.h / 2 }, .{ .x = g.x / Atlas.width, .y = g.y / Atlas.height, .w = g.w / Atlas.width, .h = g.h / Atlas.height }, color, shear);
    }

    /// A glyph drawn with a lean, for a cell whose style is italic.
    pub fn glyphShearedAt(self: *Renderer, x: f32, y: f32, cp: u21, color: Color, shear: f32) !f32 {
        const index = self.shaper.glyphIndex(cp);
        if (index == 0) {
            const fallback = try self.atlas.fallbackGlyph(cp);
            try self.drawGlyphSheared(x, y, fallback, color, shear);
            return fallback.advance;
        }
        const glyph = try self.atlas.glyphFor(cp, index);
        try self.drawGlyphSheared(x, y, glyph, color, shear);
        return self.atlas.advanceFor(cp);
    }

    /// Draw a run. Glyph selection comes from the shaper; advances come from
    /// the font metrics the atlas rasterizes with, so spacing is unchanged.
    pub fn text(self: *Renderer, x: f32, y: f32, bytes: []const u8, color: Color) !void {
        var px = x;
        var py = y;
        var i: usize = 0;
        while (i < bytes.len) {
            const cp = text_util.decode(bytes, i);
            if (cp == '\n') {
                px = x;
                py += self.atlas.line_height;
            } else if (cp == '\t') {
                px += self.atlas.advance * 4;
            } else if (cp != '\r') {
                px += try self.glyphAt(px, py + self.atlas.ascent, cp, color);
            }
            i = text_util.next(bytes, i);
        }
    }

    fn quad(self: *Renderer, bounds: Rect, uv: Rect, color: Color) !void {
        return self.quadSheared(bounds, uv, color, 0);
    }

    /// The same quad, with its top edge moved `shear` pixels right. A terminal
    /// draws italic without a second face by leaning the glyph; the atlas holds
    /// one upright bitmap, so the lean is geometry.
    fn quadSheared(self: *Renderer, bounds: Rect, uv: Rect, color: Color, shear: f32) !void {
        return self.texturedQuad(bounds, uv, color, shear, self.atlas.texture);
    }

    /// One textured quad, sampled from `texture`: what a glyph and a picture
    /// have in common, and the only place a picture differs from a glyph.
    fn texturedQuad(self: *Renderer, bounds: Rect, uv: Rect, color: Color, shear: f32, texture: *c.SDL_GPUTexture) !void {
        if (bounds.w <= 0 or bounds.h <= 0) return;
        const x0 = @max(bounds.x, self.clip.x);
        const y0 = @max(bounds.y, self.clip.y);
        const x1 = @min(bounds.x + bounds.w, self.clip.x + self.clip.w);
        const y1 = @min(bounds.y + bounds.h, self.clip.y + self.clip.h);
        if (x1 <= x0 or y1 <= y0) return;
        if (self.vertices.items.len + 6 > max_vertices) return error.FrameGeometryLimit;
        const u_min = uv.x + (x0 - bounds.x) / bounds.w * uv.w;
        const v_min = uv.y + (y0 - bounds.y) / bounds.h * uv.h;
        const u_max = uv.x + (x1 - bounds.x) / bounds.w * uv.w;
        const v_max = uv.y + (y1 - bounds.y) / bounds.h * uv.h;
        const left = x0 / self.width * 2 - 1;
        const right = x1 / self.width * 2 - 1;
        const top = 1 - y0 / self.height * 2;
        const bottom = 1 - y1 / self.height * 2;
        const offset = shear / self.width * 2;
        const tl: Vertex = .{ .position = .{ left + offset, top }, .uv = .{ u_min, v_min }, .color = color };
        const tr: Vertex = .{ .position = .{ right + offset, top }, .uv = .{ u_max, v_min }, .color = color };
        const bl: Vertex = .{ .position = .{ left, bottom }, .uv = .{ u_min, v_max }, .color = color };
        const br: Vertex = .{ .position = .{ right, bottom }, .uv = .{ u_max, v_max }, .color = color };
        try self.openSegment(texture);
        try self.vertices.appendSlice(self.allocator, &.{ tl, bl, tr, tr, bl, br });
    }

    /// Point the next six vertices at `texture`, extending the current segment
    /// when it already samples it. A segment is opened only when a quad is
    /// actually appended, so a row clipped out of its panel does not leave an
    /// empty draw behind.
    fn openSegment(self: *Renderer, texture: *c.SDL_GPUTexture) !void {
        if (self.segments.items.len != 0) {
            const last = &self.segments.items[self.segments.items.len - 1];
            if (last.texture == texture) {
                last.count += 6;
                return;
            }
        }
        try self.segments.append(self.allocator, .{ .texture = texture, .first = self.vertices.items.len, .count = 6 });
    }

    /// Draw what the frame holds: every segment in the order it was appended,
    /// with the texture it samples bound for it. While nothing but glyphs is on
    /// screen there is one segment and this is the single draw call the frame
    /// has always been.
    fn drawSegments(self: *Renderer, pass: *c.SDL_GPURenderPass) void {
        for (self.segments.items) |segment| {
            if (segment.count == 0) continue;
            const sampler: c.SDL_GPUTextureSamplerBinding = .{ .texture = segment.texture, .sampler = self.sampler };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &sampler, 1);
            c.SDL_DrawGPUPrimitives(pass, @intCast(segment.count), 1, @intCast(segment.first), 0);
        }
    }

    /// Draw one picture into `bounds`, which the caller has already fitted to
    /// the room it has. The panel's clip applies like it does to every other
    /// quad, so a picture scrolled half out of the dock is cut in half rather
    /// than drawn over its neighbours.
    pub fn drawPicture(self: *Renderer, texture: *c.SDL_GPUTexture, bounds: Rect) !void {
        try self.texturedQuad(bounds, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ 1, 1, 1, 1 }, 0, texture);
    }

    /// The picture for one record, decoded and uploaded the first time it is
    /// asked for and kept afterwards, so a picture costs one decode rather than
    /// one per frame.
    ///
    /// `key` names the record the picture belongs to - the lane and the handle
    /// the client gave it - so the same picture is drawn from every frame
    /// without decoding it again, and two pictures that happen to be alike are
    /// still two records with two textures.
    pub fn picture(self: *Renderer, key: u64, format: image.Format, bytes: []const u8) !Drawn {
        if (self.pictures.getPtr(key)) |entry| {
            entry.last = self.frame;
            return entry.state;
        }
        const decoded = try image.decode(self.allocator, format, bytes);
        var pixels = switch (decoded) {
            .picture => |bitmap| bitmap,
            .refused => |why| {
                try self.remember(key, .{ .refused = why });
                return .{ .refused = why };
            },
        };
        defer pixels.deinit(self.allocator);
        const bitmap: usize = @as(usize, pixels.width) * @as(usize, pixels.height);
        if (!self.makeRoom(bitmap)) {
            try self.remember(key, .{ .refused = .no_room });
            return .{ .refused = .no_room };
        }
        // A texture that could not be created or filled is a picture that is not
        // on screen, and that is what a reader is told: the alternative - an
        // error out of the draw - would take the frame down for a picture.
        const texture = self.upload(pixels) catch {
            try self.remember(key, .{ .refused = .no_room });
            return .{ .refused = .no_room };
        };
        const drawn: Picture = .{ .texture = texture, .width = pixels.width, .height = pixels.height };
        self.picture_pixels += bitmap;
        try self.remember(key, .{ .picture = drawn });
        return .{ .picture = drawn };
    }

    /// Remember what became of a record, so the same picture is not decoded -
    /// or refused - again on the next frame.
    fn remember(self: *Renderer, key: u64, state: Drawn) !void {
        try self.pictures.put(self.allocator, key, .{ .state = state, .last = self.frame });
    }

    /// Whether the space can hold `pixels` more, evicting what a reader has
    /// stopped looking at to make room. False when the picture is larger than
    /// the whole space, which is refused before anything is evicted so that one
    /// oversized image cannot empty the cache and then fail anyway.
    fn makeRoom(self: *Renderer, pixels: usize) bool {
        if (pixels > max_picture_pixels) return false;
        while (self.pictures.count() >= max_pictures or self.picture_pixels + pixels > max_picture_pixels) {
            if (!self.evictOldest()) return true;
        }
        return true;
    }

    /// Release the picture last asked for longest ago, or the plainest entry
    /// when there is none: a refusal costs no pixels and is still an entry.
    /// False when there is nothing left to give up.
    fn evictOldest(self: *Renderer) bool {
        var oldest_key: ?u64 = null;
        var oldest: u64 = std.math.maxInt(u64);
        var entries = self.pictures.iterator();
        while (entries.next()) |entry| {
            if (entry.value_ptr.last >= oldest) continue;
            oldest = entry.value_ptr.last;
            oldest_key = entry.key_ptr.*;
        }
        const key = oldest_key orelse return false;
        self.forget(key);
        return true;
    }

    fn forget(self: *Renderer, key: u64) void {
        const entry = self.pictures.fetchRemove(key) orelse return;
        switch (entry.value.state) {
            .picture => |drawn| {
                c.SDL_ReleaseGPUTexture(self.device, drawn.texture);
                self.picture_pixels -= @as(usize, drawn.width) * @as(usize, drawn.height);
            },
            .refused => {},
        }
    }

    fn releasePictures(self: *Renderer) void {
        var entries = self.pictures.iterator();
        while (entries.next()) |entry| {
            switch (entry.value_ptr.state) {
                .picture => |drawn| c.SDL_ReleaseGPUTexture(self.device, drawn.texture),
                .refused => {},
            }
        }
        self.pictures.clearRetainingCapacity();
        self.picture_pixels = 0;
    }

    /// A texture of the picture's own, filled from the decoded pixels. The
    /// format is the one the decoder produces - RGBA, unorm - so nothing is
    /// converted on the way in.
    fn upload(self: *Renderer, pixels: image.Picture) !*c.SDL_GPUTexture {
        var texture_info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        texture_info.type = c.SDL_GPU_TEXTURETYPE_2D;
        texture_info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        texture_info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        texture_info.width = pixels.width;
        texture_info.height = pixels.height;
        texture_info.layer_count_or_depth = 1;
        texture_info.num_levels = 1;
        const texture = c.SDL_CreateGPUTexture(self.device, &texture_info) orelse return error.GpuTexture;
        errdefer c.SDL_ReleaseGPUTexture(self.device, texture);
        var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
        transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        transfer_info.size = @intCast(pixels.pixels.len);
        const transfer = c.SDL_CreateGPUTransferBuffer(self.device, &transfer_info) orelse return error.GpuTransfer;
        defer c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);
        const command = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.GpuCommand;
        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.device, transfer, true) orelse {
            _ = c.SDL_CancelGPUCommandBuffer(command);
            return error.GpuMap;
        });
        @memcpy(mapped[0..pixels.pixels.len], pixels.pixels);
        c.SDL_UnmapGPUTransferBuffer(self.device, transfer);
        const copy = c.SDL_BeginGPUCopyPass(command) orelse {
            _ = c.SDL_CancelGPUCommandBuffer(command);
            return error.GpuCopyPass;
        };
        var from = std.mem.zeroes(c.SDL_GPUTextureTransferInfo);
        from.transfer_buffer = transfer;
        var region = std.mem.zeroes(c.SDL_GPUTextureRegion);
        region.texture = texture;
        region.w = pixels.width;
        region.h = pixels.height;
        region.d = 1;
        c.SDL_UploadToGPUTexture(copy, &from, &region, false);
        c.SDL_EndGPUCopyPass(copy);
        if (!c.SDL_SubmitGPUCommandBuffer(command)) return error.GpuSubmit;
        return texture;
    }

    /// Render the current vertices into an offscreen texture, read it back, and
    /// write a binary PPM (P6) at `path`. The screenshot gate uses this so the
    /// GPU path can be compared without relying on window contents.
    ///
    /// The offscreen target matches the layout the caller drew into and the
    /// format the pipeline was created for. A different size would scale the
    /// capture, and a different format makes the render pass incompatible with
    /// the pipeline.
    /// Write the current frame to `path`, in the format the name asks for.
    ///
    /// This exists for QA: a run that has to be looked at afterwards, or a gate
    /// that reads pixels rather than strings. The download gives back the
    /// swapchain's own format - BGRA on the backends that use it - so the
    /// pixels are put in RGBA order once here and every encoder then takes the
    /// same buffer. An unfamiliar extension is refused rather than guessed at,
    /// because a run that silently got a different format than it asked for is
    /// worse than one that failed.
    pub fn capture(self: *Renderer, io: std.Io, a: std.mem.Allocator, path: []const u8) !void {
        try self.atlas.flush();
        const width: u32 = @intFromFloat(@max(1, self.width));
        const height: u32 = @intFromFloat(@max(1, self.height));
        const format = c.SDL_GetGPUSwapchainTextureFormat(self.device, self.window);
        var texture_info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        texture_info.type = c.SDL_GPU_TEXTURETYPE_2D;
        texture_info.format = format;
        texture_info.usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        texture_info.width = width;
        texture_info.height = height;
        texture_info.layer_count_or_depth = 1;
        texture_info.num_levels = 1;
        const texture = c.SDL_CreateGPUTexture(self.device, &texture_info) orelse return error.GpuTexture;
        defer c.SDL_ReleaseGPUTexture(self.device, texture);
        var transfer_info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
        transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        transfer_info.size = width * height * 4;
        const transfer = c.SDL_CreateGPUTransferBuffer(self.device, &transfer_info) orelse return error.GpuTransfer;
        defer c.SDL_ReleaseGPUTransferBuffer(self.device, transfer);
        const command = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.GpuCommand;
        const bytes = std.mem.sliceAsBytes(self.vertices.items);
        if (bytes.len > 0) {
            const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.device, self.transfer, true) orelse {
                _ = c.SDL_SubmitGPUCommandBuffer(command);
                return error.GpuMap;
            });
            @memcpy(mapped[0..bytes.len], bytes);
            c.SDL_UnmapGPUTransferBuffer(self.device, self.transfer);
            const copy = c.SDL_BeginGPUCopyPass(command) orelse {
                _ = c.SDL_SubmitGPUCommandBuffer(command);
                return error.GpuCopyPass;
            };
            const source: c.SDL_GPUTransferBufferLocation = .{ .transfer_buffer = self.transfer, .offset = 0 };
            const destination: c.SDL_GPUBufferRegion = .{ .buffer = self.vertex_buffer, .offset = 0, .size = @intCast(bytes.len) };
            c.SDL_UploadToGPUBuffer(copy, &source, &destination, true);
            c.SDL_EndGPUCopyPass(copy);
        }
        var target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        target.texture = texture;
        target.load_op = c.SDL_GPU_LOADOP_CLEAR;
        target.store_op = c.SDL_GPU_STOREOP_STORE;
        target.clear_color = .{ .r = 0.06, .g = 0.07, .b = 0.09, .a = 1 };
        const pass = c.SDL_BeginGPURenderPass(command, &target, 1, null) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(command);
            return error.GpuRenderPass;
        };
        c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
        const binding: c.SDL_GPUBufferBinding = .{ .buffer = self.vertex_buffer, .offset = 0 };
        c.SDL_BindGPUVertexBuffers(pass, 0, &binding, 1);
        self.drawSegments(pass);
        c.SDL_EndGPURenderPass(pass);
        const download = c.SDL_BeginGPUCopyPass(command) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(command);
            return error.GpuCopyPass;
        };
        var region = std.mem.zeroes(c.SDL_GPUTextureRegion);
        region.texture = texture;
        region.w = width;
        region.h = height;
        region.d = 1;
        var download_info = std.mem.zeroes(c.SDL_GPUTextureTransferInfo);
        download_info.transfer_buffer = transfer;
        c.SDL_DownloadFromGPUTexture(download, &region, &download_info);
        c.SDL_EndGPUCopyPass(download);
        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(command) orelse return error.GpuSubmit;
        _ = c.SDL_WaitForGPUFences(self.device, true, &fence, 1);
        c.SDL_ReleaseGPUFence(self.device, fence);
        const pixels: [*]const u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.device, transfer, false) orelse return error.GpuMap);
        defer c.SDL_UnmapGPUTransferBuffer(self.device, transfer);
        // PPM is kept because none of the codecs here writes one, and a plain
        // raster dump is occasionally what a pixel diff wants.
        if (std.mem.endsWith(u8, path, ".ppm") or std.mem.endsWith(u8, path, ".pnm")) {
            return writePpm(self.allocator, path, pixels, width, height, isBgra(format));
        }
        const framebuffer = try rgbaPixels(a, pixels, width, height, isBgra(format));
        defer a.free(framebuffer);
        const shot = zignal.Image(zignal.Rgba(u8)).initFromSlice(height, width, framebuffer);
        if (std.mem.endsWith(u8, path, ".png")) return zignal.png.save(zignal.Rgba(u8), io, a, shot, path);
        if (std.mem.endsWith(u8, path, ".bmp")) return zignal.bmp.save(zignal.Rgba(u8), io, a, shot, path);
        if (std.mem.endsWith(u8, path, ".gif")) return zignal.gif.save(zignal.Rgba(u8), io, a, shot, path);
        if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) {
            return zignal.jpeg.save(zignal.Rgba(u8), io, a, shot, path);
        }
        return error.UnknownCaptureFormat;
    }

    /// The frame's pixels in RGBA order, which is the order every encoder here
    /// takes. The swapchain hands back its own order, so this puts it right once
    /// rather than each encoder being told about it.
    fn rgbaPixels(a: std.mem.Allocator, pixels: [*]const u8, width: u32, height: u32, bgra: bool) ![]zignal.Rgba(u8) {
        const out = try a.alloc(zignal.Rgba(u8), @as(usize, width) * height);
        for (out, 0..) |*pixel, i| {
            const at = i * 4;
            pixel.* = .{
                .r = if (bgra) pixels[at + 2] else pixels[at],
                .g = pixels[at + 1],
                .b = if (bgra) pixels[at] else pixels[at + 2],
                .a = pixels[at + 3],
            };
        }
        return out;
    }

    /// True when the format stores blue before red, which the PPM writer swaps.
    fn isBgra(format: c.SDL_GPUTextureFormat) bool {
        return format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM or format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB;
    }

    fn writePpm(a: std.mem.Allocator, path: []const u8, pixels: [*]const u8, width: u32, height: u32, swap_red_blue: bool) !void {
        const z = try a.dupeSentinel(u8, path, 0);
        defer a.free(z);
        const stream = c.SDL_IOFromFile(z.ptr, "wb") orelse return error.FileOpen;
        defer _ = c.SDL_CloseIO(stream);
        var header: [64]u8 = undefined;
        const header_text = try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ width, height });
        if (c.SDL_WriteIO(stream, header_text.ptr, header_text.len) != header_text.len) return error.FileWrite;
        const row = try a.alloc(u8, width * 3);
        defer a.free(row);
        for (0..height) |y| {
            for (0..width) |x| {
                const source = (y * width + x) * 4;
                const red = if (swap_red_blue) pixels[source + 2] else pixels[source];
                const blue = if (swap_red_blue) pixels[source] else pixels[source + 2];
                row[x * 3] = red;
                row[x * 3 + 1] = pixels[source + 1];
                row[x * 3 + 2] = blue;
            }
            if (c.SDL_WriteIO(stream, row.ptr, row.len) != row.len) return error.FileWrite;
        }
    }

    pub fn present(self: *Renderer) !void {
        try self.atlas.flush();
        const command = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.GpuCommand;
        var texture: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(command, self.window, &texture, &width, &height)) {
            _ = c.SDL_CancelGPUCommandBuffer(command);
            return error.GpuSwapchain;
        }
        // A minimized window can return success with no texture.
        if (texture == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(command);
            c.SDL_Delay(16);
            return;
        }
        const bytes = std.mem.sliceAsBytes(self.vertices.items);
        if (bytes.len > 0) {
            const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.device, self.transfer, true) orelse {
                _ = c.SDL_SubmitGPUCommandBuffer(command);
                return error.GpuMap;
            });
            @memcpy(mapped[0..bytes.len], bytes);
            c.SDL_UnmapGPUTransferBuffer(self.device, self.transfer);
            const copy = c.SDL_BeginGPUCopyPass(command) orelse {
                _ = c.SDL_SubmitGPUCommandBuffer(command);
                return error.GpuCopyPass;
            };
            const source: c.SDL_GPUTransferBufferLocation = .{ .transfer_buffer = self.transfer, .offset = 0 };
            const destination: c.SDL_GPUBufferRegion = .{ .buffer = self.vertex_buffer, .offset = 0, .size = @intCast(bytes.len) };
            c.SDL_UploadToGPUBuffer(copy, &source, &destination, true);
            c.SDL_EndGPUCopyPass(copy);
        }
        var target = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
        target.texture = texture;
        target.load_op = c.SDL_GPU_LOADOP_CLEAR;
        target.store_op = c.SDL_GPU_STOREOP_STORE;
        target.clear_color = .{ .r = 0.06, .g = 0.07, .b = 0.09, .a = 1 };
        const pass = c.SDL_BeginGPURenderPass(command, &target, 1, null) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(command);
            return error.GpuRenderPass;
        };
        c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
        const binding: c.SDL_GPUBufferBinding = .{ .buffer = self.vertex_buffer, .offset = 0 };
        c.SDL_BindGPUVertexBuffers(pass, 0, &binding, 1);
        self.drawSegments(pass);
        c.SDL_EndGPURenderPass(pass);
        if (!c.SDL_SubmitGPUCommandBuffer(command)) return error.GpuSubmit;
    }
};
