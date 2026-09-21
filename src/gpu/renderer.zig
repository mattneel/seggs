const std = @import("std");

var diag_count: usize = 0;
var shear_log: usize = 0;
const builtin = @import("builtin");
const c = @import("native");
const shaders = @import("shaders");
const Atlas = @import("atlas.zig").Atlas;
const Shaper = @import("shaper.zig").Shaper;
const Rect = @import("../ui/layout.zig").Rect;
const Color = @import("../ui/theme.zig").Color;
const text_util = @import("../core/text.zig");

pub const Renderer = struct {
    const Vertex = extern struct { position: [2]f32, uv: [2]f32, color: Color };
    const max_vertices = 262_144;
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
        self.width = @max(1, width);
        self.height = @max(1, height);
        self.clip = .{ .x = 0, .y = 0, .w = self.width, .h = self.height };
    }

    pub fn rect(self: *Renderer, bounds: Rect, color: Color) !void {
        try self.quad(bounds, .{ .x = Atlas.solid_u, .y = Atlas.solid_v, .w = 0, .h = 0 }, color);
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
        try self.vertices.appendSlice(self.allocator, &.{ tl, bl, tr, tr, bl, br });
    }

    /// Render the current vertices into an offscreen texture, read it back, and
    /// write a binary PPM (P6) at `path`. The screenshot gate uses this so the
    /// GPU path can be compared without relying on window contents.
    ///
    /// The offscreen target matches the layout the caller drew into and the
    /// format the pipeline was created for. A different size would scale the
    /// capture, and a different format makes the render pass incompatible with
    /// the pipeline.
    pub fn capture(self: *Renderer, path: []const u8) !void {
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
        const sampler: c.SDL_GPUTextureSamplerBinding = .{ .texture = self.atlas.texture, .sampler = self.sampler };
        c.SDL_BindGPUFragmentSamplers(pass, 0, &sampler, 1);
        if (self.vertices.items.len > 0) c.SDL_DrawGPUPrimitives(pass, @intCast(self.vertices.items.len), 1, 0, 0);
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
        try writePpm(self.allocator, path, pixels, width, height, isBgra(format));
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
        const sampler: c.SDL_GPUTextureSamplerBinding = .{ .texture = self.atlas.texture, .sampler = self.sampler };
        c.SDL_BindGPUFragmentSamplers(pass, 0, &sampler, 1);
        if (self.vertices.items.len > 0) c.SDL_DrawGPUPrimitives(pass, @intCast(self.vertices.items.len), 1, 0, 0);
        c.SDL_EndGPURenderPass(pass);
        if (!c.SDL_SubmitGPUCommandBuffer(command)) return error.GpuSubmit;
    }
};
