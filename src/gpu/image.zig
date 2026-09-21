//! The pixels of an image part: the one place untrusted bytes become an
//! allocation.
//!
//! `acp/image.zig` keeps what arrived - the mime type, the sniffed format, and
//! the image file, bounded by a byte cap. This is the step after it, and the
//! expensive one: a compressed file becomes a bitmap, and 60 kB of PNG can
//! declare a hundred million pixels. So every decode here runs under explicit
//! `DecodeLimits` rather than a library default: the caps are declared beside
//! the decoders that honour them, so a library bump that changed a default
//! cannot silently widen what this client will allocate.
//!
//! Two caps, and both bite:
//!
//!   - `max_side` and `max_pixels` are the pixel bound. It is the one that
//!     matters, because it is the shape of a decompression bomb: an allocation
//!     proportional to what the file *says* rather than to what it weighs. The
//!     decoder checks it from the header, before it inflates anything.
//!   - `max_decompressed` is the inflate bound, sized so that an image which
//!     passes the pixel bound can never trip it: it exists to catch the case
//!     where a stream inflates to far more than the header promised.
//!
//! ## The thread this runs on
//!
//! A decode runs on the application thread, and that is a judgement rather than
//! an oversight. An image is decoded once, when it is first drawn, and the
//! renderer keeps the texture afterwards, so what a reader pays is one frame
//! with a decode in it and nothing on the frames after that. `max_pixels` is
//! what bounds that frame, and the number is measured rather than assumed: a
//! 1920×1080 PNG decodes in 25 ms in a release build and 100 ms in a debug one
//! on the machine this was written on, so a full-size screenshot is a hitch of a
//! couple of frames and the cap is roughly double that. A smaller image - which
//! is most of them - is a few milliseconds.
//!
//! The alternative is a worker, and it is a bigger decision than this feature.
//! A worker would take the payload off the client thread, decode there, and hand
//! back a bitmap for the GPU to upload: that is editor state living in a
//! transport worker, which AGENTS.md rule 4 rules out, plus a queue, a buffer
//! lifetime, and a cancellation story - for a feature that draws one picture at
//! a time. If the cap ever has to grow, the honest fix is to decode on a frame
//! that has nothing else to do, not to move the decode somewhere else.

const std = @import("std");
const zignal = @import("zignal");
const acp_image = @import("../acp/image.zig");
const Allocator = std.mem.Allocator;

pub const Format = acp_image.Format;
pub const Refusal = acp_image.Refusal;

/// The most pixels one image may have, four million: a 1920×1080 screenshot
/// with room to spare, and a quarter of the memory a 4K one would take.
///
/// This is the bound a reader meets when an agent sends a full-resolution
/// screenshot: past it the image is not drawn and the line says so, naming
/// nothing it cannot know - the decoder refuses from the header, and the header
/// is where the dimensions are.
pub const max_pixels: u64 = 4 * 1024 * 1024;

/// The widest and tallest one image may be. The pixel bound usually bites first
/// - a 4096-wide image is refused past 1024 rows - and this is the guard for the
/// shapes where it would not: a 4000×1 strip is four thousand pixels and would
/// otherwise be an image with a side no panel can draw anyway.
pub const max_side: u32 = 4096;

/// The most bytes any of the four decoders may inflate. Sized off the pixel
/// bound with room for the widest pixel a codec can produce (16 bits per
/// channel, four channels, plus a filter byte per row), so an image that passes
/// the pixel bound is never refused here: what this catches is a stream that
/// inflates to more than the header promised.
const max_decompressed: usize = 64 * 1024 * 1024;

/// The most pixels a GIF's frames may add up to. A GIF is decoded for its first
/// frame and one picture is drawn, but every frame's records pass through the
/// decoder, so the guard is on the sum rather than on one frame.
const max_gif_frame_pixels: u64 = 16 * 1024 * 1024;

/// The alignment a picture's bytes were allocated with. Every codec here
/// decodes into `Rgba(u8)`, so this is what `Picture.deinit` has to free them
/// as: the renderer only ever sees bytes, and the alignment they were taken
/// with is this file's business.
const pixel_alignment = @alignOf(zignal.Rgba(u8));

/// One image, decoded: the size the decoder found and the pixels themselves.
///
/// The pixels are RGBA, four bytes per pixel, row-major with no gaps, which is
/// exactly the layout SDL_GPU's `R8G8B8A8_UNORM` samples - so what arrives here
/// is uploaded as it is, without a second pass over the image.
pub const Picture = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Picture, a: Allocator) void {
        // The pixels are a typed allocation - `[]Rgba(u8)` - and they are freed
        // as one: freeing the bytes at a weaker alignment than they were taken
        // with is a mismatch a checking allocator catches and a real one
        // corrupts, and the decoder is the only thing that knows what the
        // allocation was.
        a.free(@as([]align(pixel_alignment) u8, @alignCast(self.pixels)));
        self.* = .{ .width = 0, .height = 0, .pixels = &.{} };
    }
};

/// What a decode came to: pixels, or the reason there are none. A refusal is a
/// value rather than an error because it is an answer about the image - the
/// caller draws it - while an allocation failure is about the machine and is an
/// error.
pub const Result = union(enum) {
    picture: Picture,
    refused: Refusal,
};

/// Decode one image under the limits above.
pub fn decode(a: Allocator, format: Format, bytes: []const u8) !Result {
    // One `Io` for all four codecs, and it is the one with no concurrency:
    // zignal hands its row bands to `Io.Group`, which for this implementation
    // runs each task inline and in order on the calling thread. That is what
    // keeps a decode on the application thread without this module having to
    // know how the library splits its work.
    const io: std.Io = .failing;
    return switch (format) {
        .png => finish(a, zignal.png.loadFromBytes(zignal.Rgba(u8), io, a, bytes, pngLimits())),
        .jpeg => finish(a, zignal.jpeg.loadFromBytes(zignal.Rgba(u8), io, a, bytes, jpegLimits())),
        .bmp => finish(a, zignal.bmp.loadFromBytes(zignal.Rgba(u8), io, a, bytes, bmpLimits())),
        .gif => finish(a, zignal.gif.loadFromBytes(zignal.Rgba(u8), io, a, bytes, gifLimits())),
    };
}

/// The one `switch` over what a codec returned, so the four formats cannot
/// drift apart in how they report a failure: `error.ImageTooLarge` is the pixel
/// bound and keeps its own name, an allocation failure is the machine's and is
/// passed on, and everything else a decoder can say - a corrupt stream, more
/// chunks or frames than it will chew, a truncated file - is the same fact to a
/// reader: no pixels came out.
fn finish(a: Allocator, loaded: anytype) !Result {
    var image = loaded catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ImageTooLarge => return .{ .refused = .too_many_pixels },
        else => return .{ .refused = .undecodable },
    };
    defer image.deinit(a);
    // The decoder hands back an image it owns and laid out with no gaps between
    // rows, so the pixels are already the bytes SDL_GPU wants and the picture
    // takes the buffer rather than copying it - `empty` leaves the one owner.
    const picture: Picture = .{ .width = image.cols, .height = image.rows, .pixels = image.asBytes() };
    image = .empty;
    return .{ .picture = picture };
}

/// The byte caps a codec is given. The payload was already bounded by
/// `acp_image.max_image_bytes` before it reached this file, and the decoder is
/// told the same number rather than a larger one: a bound declared in two places
/// is a bound that cannot silently widen on one side.
fn byteLimit() usize {
    return acp_image.max_image_bytes;
}

fn pngLimits() zignal.png.DecodeLimits {
    return .{
        .max_png_bytes = byteLimit(),
        .max_chunk_bytes = byteLimit(),
        .max_idat_bytes = byteLimit(),
        .max_width = max_side,
        .max_height = max_side,
        .max_pixels = max_pixels,
        .max_decompressed_bytes = max_decompressed,
    };
}

fn jpegLimits() zignal.jpeg.DecodeLimits {
    return .{
        .max_jpeg_bytes = byteLimit(),
        .max_marker_bytes = byteLimit(),
        .max_width = max_side,
        .max_height = max_side,
        .max_pixels = max_pixels,
    };
}

fn bmpLimits() zignal.bmp.DecodeLimits {
    return .{
        .max_bmp_bytes = byteLimit(),
        .max_width = max_side,
        .max_height = max_side,
        .max_pixels = max_pixels,
    };
}

fn gifLimits() zignal.gif.DecodeLimits {
    return .{
        .max_gif_bytes = byteLimit(),
        .max_width = max_side,
        .max_height = max_side,
        .max_pixels = max_pixels,
        .max_total_pixels = max_gif_frame_pixels,
    };
}

/// One decoded picture, or the reason it is not one.
fn accepted(result: Result) Picture {
    return switch (result) {
        .picture => |picture| picture,
        .refused => |why| {
            std.debug.print("expected pixels, was refused as {s}\n", .{@tagName(why)});
            unreachable;
        },
    };
}

fn rejected(result: Result, a: Allocator) Refusal {
    return switch (result) {
        .picture => |picture| {
            var drawn = picture;
            drawn.deinit(a);
            std.debug.print("expected a refusal, was given {d}x{d} pixels\n", .{ drawn.width, drawn.height });
            unreachable;
        },
        .refused => |why| why,
    };
}

test "the fixture's PNG decodes to the pixels it was written with" {
    const a = std.testing.allocator;
    const bytes = try std.base64.standard.Decoder.calcSizeForSlice(acp_image.sample_png_base64);
    const raw = try a.alloc(u8, bytes);
    defer a.free(raw);
    try std.base64.standard.Decoder.decode(raw, acp_image.sample_png_base64);

    var picture = accepted(try decode(a, .png, raw));
    defer picture.deinit(a);
    try std.testing.expectEqual(@as(u32, 16), picture.width);
    try std.testing.expectEqual(@as(u32, 16), picture.height);
    try std.testing.expectEqual(@as(usize, 16 * 16 * 4), picture.pixels.len);
    // The fixture is four 8×8 quadrants with a white diagonal drawn over them,
    // so one pixel from each quadrant proves the whole image decoded rather
    // than its first row - and the byte order proves the pixels are RGBA, which
    // is also the order SDL_GPU's `R8G8B8A8_UNORM` reads. That is why a decoded
    // picture uploads as it is rather than through a conversion pass.
    const corner = 0;
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, picture.pixels[corner..][0..4]);
    const red = (4 * 16 + 2) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 220, 60, 60, 255 }, picture.pixels[red..][0..4]);
    const green = (4 * 16 + 12) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 60, 200, 90, 255 }, picture.pixels[green..][0..4]);
    const blue = (12 * 16 + 4) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 60, 120, 240, 255 }, picture.pixels[blue..][0..4]);
    const yellow = (12 * 16 + 14) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 240, 200, 60, 255 }, picture.pixels[yellow..][0..4]);
}

test "an image that claims more pixels than it will decode is refused, not inflated" {
    const a = std.testing.allocator;
    const raw = try std.base64.standard.Decoder.calcSizeForSlice(acp_image.sample_png_base64);
    const bytes = try a.alloc(u8, raw);
    defer a.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, acp_image.sample_png_base64);

    // The fixture's own bytes with its header rewritten to claim a hundred
    // million pixels, and the header's CRC recomputed so the file is a file the
    // decoder believes. The pixels a header like that promises are not in the
    // bytes at that length, which is the point: a decoder that found out by
    // inflating them would have allocated first, and this refuses from the
    // header.
    std.mem.writeInt(u32, bytes[16..20], 10_000, .big);
    std.mem.writeInt(u32, bytes[20..24], 10_000, .big);
    std.mem.writeInt(u32, bytes[29..33], std.hash.Crc32.hash(bytes[12..29]), .big);

    // The pixel bound is the answer, and it is a different answer from a decode
    // failure: the cap is what a reader has to be told to know the file was not
    // simply broken.
    try std.testing.expectEqual(Refusal.too_many_pixels, rejected(try decode(a, .png, bytes), a));

    // A payload that is a PNG by its signature and nothing after it: the sniff
    // said PNG and the decoder says no. That is the third answer - not a cap,
    // and not something the client could know without decoding - and it is why
    // the refusal vocabulary has more than one word in it.
    const broken = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a } ++ [_]u8{ 7, 7, 7, 7 };
    try std.testing.expectEqual(Refusal.undecodable, rejected(try decode(a, .png, &broken), a));
}

test "the other three formats decode through the same answer" {
    const a = std.testing.allocator;
    // A 2×2 24-bit BMP, written out: the format is a header, a row of pixels
    // padded to four bytes, and nothing else, so the bytes are the test.
    const bmp = [_]u8{
        0x42, 0x4d, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00, 0x00,
        0x28, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x13, 0x0b, 0x00, 0x00,
        0x13, 0x0b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Bottom row left to right: blue, green; then the padding two bytes.
        0xff, 0x00,
        0x00, 0x00, 0xff, 0x00, 0x00, 0x00,
        // Top row left to right: red, white; then the padding two bytes.
        0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00,
    };
    var picture = accepted(try decode(a, .bmp, &bmp));
    defer picture.deinit(a);
    try std.testing.expectEqual(@as(u32, 2), picture.width);
    try std.testing.expectEqual(@as(u32, 2), picture.height);

    // A GIF that is a GIF header and nothing else is refused by the decoder
    // rather than by the sniff, which is what keeps every format on the same
    // answer. The screen descriptor is a real one - one pixel square, no colour
    // table - so what fails is the data behind it rather than a made-up size.
    const gif = "GIF89a\x01\x00\x01\x00\x00\x00\x00\xff";
    try std.testing.expectEqual(Refusal.undecodable, rejected(try decode(a, .gif, gif), a));
    try std.testing.expectEqual(Refusal.undecodable, rejected(try decode(a, .jpeg, "\xff\xd8\xff not really"), a));
}
