const std = @import("std");
const c = @import("native");

/// Startup-only ASCII atlas. No font file is bundled or redistributed.
pub const Atlas = struct {
    pub const width = 1024;
    pub const height = 512;
    pub const Glyph = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
    texture: *c.SDL_GPUTexture,
    glyphs: [128]Glyph,
    advance: f32,
    line_height: f32,

    pub fn init(device: *c.SDL_GPUDevice, font_path: [*:0]const u8) !Atlas {
        const font = c.TTF_OpenFont(font_path, 32) orelse return error.FontOpen;
        defer c.TTF_CloseFont(font);
        var advance: c_int = 0;
        if (!c.TTF_GetGlyphMetrics(font, 'M', null, null, null, null, &advance)) return error.FontMetrics;
        const surface = c.SDL_CreateSurface(width, height, c.SDL_PIXELFORMAT_RGBA32) orelse return error.AtlasSurface;
        defer c.SDL_DestroySurface(surface);
        _ = c.SDL_FillSurfaceRect(surface, null, c.SDL_MapSurfaceRGBA(surface, 0, 0, 0, 0));
        const white = c.SDL_MapSurfaceRGBA(surface, 255, 255, 255, 255);
        const white_rect: c.SDL_Rect = .{ .x = 0, .y = 0, .w = 4, .h = 4 };
        _ = c.SDL_FillSurfaceRect(surface, &white_rect, white);
        var glyphs = [_]Glyph{.{}} ** 128;
        for (33..127) |codepoint| {
            const glyph = c.TTF_RenderGlyph_Blended(font, @intCast(codepoint), .{ .r = 255, .g = 255, .b = 255, .a = 255 }) orelse return error.GlyphRaster;
            defer c.SDL_DestroySurface(glyph);
            const slot = codepoint - 32;
            const x: c_int = @intCast((slot % 16) * 64 + 8);
            const y: c_int = @intCast((slot / 16) * 72 + 8);
            if (glyph.*.w > 54 or glyph.*.h > 64) return error.FontTooLarge;
            const dst: c.SDL_Rect = .{ .x = x, .y = y, .w = glyph.*.w, .h = glyph.*.h };
            // Copy straight alpha. Alpha blend during atlas construction darkens edges.
            _ = c.SDL_SetSurfaceBlendMode(glyph, c.SDL_BLENDMODE_NONE);
            if (!c.SDL_BlitSurface(glyph, null, surface, &dst)) return error.GlyphBlit;
            glyphs[codepoint] = .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(glyph.*.w), .h = @floatFromInt(glyph.*.h) };
        }
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
        defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse return error.AtlasMap);
        const pixels: [*]const u8 = @ptrCast(surface.*.pixels.?);
        const pitch: usize = @intCast(surface.*.pitch);
        for (0..height) |row| @memcpy(mapped[row * width * 4 ..][0 .. width * 4], pixels[row * pitch ..][0 .. width * 4]);
        c.SDL_UnmapGPUTransferBuffer(device, transfer);
        const command = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.GpuCommand;
        const pass = c.SDL_BeginGPUCopyPass(command) orelse {
            _ = c.SDL_CancelGPUCommandBuffer(command);
            return error.GpuCopyPass;
        };
        var source = std.mem.zeroes(c.SDL_GPUTextureTransferInfo);
        source.transfer_buffer = transfer;
        var destination = std.mem.zeroes(c.SDL_GPUTextureRegion);
        destination.texture = texture;
        destination.w = width;
        destination.h = height;
        destination.d = 1;
        c.SDL_UploadToGPUTexture(pass, &source, &destination, false);
        c.SDL_EndGPUCopyPass(pass);
        if (!c.SDL_SubmitGPUCommandBuffer(command)) return error.GpuSubmit;
        return .{
            .texture = texture,
            .glyphs = glyphs,
            .advance = @as(f32, @floatFromInt(advance)) / 2,
            .line_height = @max(22, @as(f32, @floatFromInt(c.TTF_GetFontLineSkip(font))) / 2),
        };
    }
};
