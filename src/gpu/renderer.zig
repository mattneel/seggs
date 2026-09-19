const std = @import("std");
const builtin = @import("builtin");
const c = @import("native");
const shaders = @import("shaders");
const Atlas = @import("atlas.zig").Atlas;
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
    vertices: std.ArrayList(Vertex) = .empty,
    width: f32 = 1,
    height: f32 = 1,
    clip: Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },

    pub fn init(a: std.mem.Allocator, window: *c.SDL_Window, font: [*:0]const u8) !Renderer {
        const metal = builtin.os.tag == .macos;
        const format = if (metal) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV;
        const device = c.SDL_CreateGPUDevice(format, builtin.mode == .Debug, null) orelse return error.GpuDevice;
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
        const atlas = try Atlas.init(device, font);
        return .{ .allocator = a, .window = window, .device = device, .pipeline = pipeline, .vertex_buffer = vertex_buffer, .transfer = transfer, .sampler = sampler, .atlas = atlas };
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
        c.SDL_ReleaseGPUTexture(self.device, self.atlas.texture);
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
        try self.quad(bounds, .{ .x = 1.5 / Atlas.width, .y = 1.5 / Atlas.height, .w = 0, .h = 0 }, color);
    }

    pub fn glyph(self: *Renderer, x: f32, y: f32, byte: u8, color: Color) !void {
        const g = self.atlas.glyphs[if (byte >= 32 and byte < 127) byte else '?'];
        try self.quad(.{ .x = x, .y = y, .w = g.w / 2, .h = g.h / 2 }, .{ .x = g.x / Atlas.width, .y = g.y / Atlas.height, .w = g.w / Atlas.width, .h = g.h / Atlas.height }, color);
    }

    pub fn text(self: *Renderer, x: f32, y: f32, bytes: []const u8, color: Color) !void {
        var px = x;
        var py = y;
        var i: usize = 0;
        while (i < bytes.len) {
            const byte = bytes[i];
            if (byte == '\n') {
                px = x;
                py += self.atlas.line_height;
            } else if (byte == '\t') {
                px += self.atlas.advance * 4;
            } else if (byte != '\r') {
                try self.glyph(px, py, byte, color);
                px += self.atlas.advance;
            }
            i = text_util.next(bytes, i);
        }
    }

    fn quad(self: *Renderer, bounds: Rect, uv: Rect, color: Color) !void {
        if (bounds.w <= 0 or bounds.h <= 0) return;
        const x0 = @max(bounds.x, self.clip.x);
        const y0 = @max(bounds.y, self.clip.y);
        const x1 = @min(bounds.x + bounds.w, self.clip.x + self.clip.w);
        const y1 = @min(bounds.y + bounds.h, self.clip.y + self.clip.h);
        if (x1 <= x0 or y1 <= y0) return;
        if (self.vertices.items.len + 6 > max_vertices) return error.FrameGeometryLimit;
        const u0 = uv.x + (x0 - bounds.x) / bounds.w * uv.w;
        const v0 = uv.y + (y0 - bounds.y) / bounds.h * uv.h;
        const u1 = uv.x + (x1 - bounds.x) / bounds.w * uv.w;
        const v1 = uv.y + (y1 - bounds.y) / bounds.h * uv.h;
        const left = x0 / self.width * 2 - 1;
        const right = x1 / self.width * 2 - 1;
        const top = 1 - y0 / self.height * 2;
        const bottom = 1 - y1 / self.height * 2;
        const tl: Vertex = .{ .position = .{ left, top }, .uv = .{ u0, v0 }, .color = color };
        const tr: Vertex = .{ .position = .{ right, top }, .uv = .{ u1, v0 }, .color = color };
        const bl: Vertex = .{ .position = .{ left, bottom }, .uv = .{ u0, v1 }, .color = color };
        const br: Vertex = .{ .position = .{ right, bottom }, .uv = .{ u1, v1 }, .color = color };
        try self.vertices.appendSlice(self.allocator, &.{ tl, bl, tr, tr, bl, br });
    }

    pub fn present(self: *Renderer) !void {
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
