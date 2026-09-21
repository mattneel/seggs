//! A picture an agent sent: the one content part whose payload is not words.
//!
//! ACP's content blocks are not all text. An `image` block carries a mime type
//! and a base64 payload, and until now a part like that was counted and moved
//! on: the run it arrived in said `1 part not text` and the pixels were gone. A
//! message with a picture in it is not a message with a gap in it, so an image
//! part becomes a record of its own instead - where it arrived (`at`, the same
//! offset a tool call and a run carry, for the same reason: an interface draws
//! it where it happened), what it says it is (`mime`), what it really is
//! (`format`, sniffed from the bytes), and the image file it carried.
//!
//! base64 is transport and not storage, so the payload is decoded here, once.
//! Nothing else is done with it: turning bytes into pixels is bounded work that
//! belongs to the drawing side (`gpu/image.zig`, which decodes under limits of
//! its own), and a record holding a bitmap would charge the client for every
//! image an agent ever sends whether or not a reader looks at it.
//!
//! Every bound bites as its own fact. A payload that is not base64, a mime type
//! this client does not read, a payload past `max_image_bytes`, and bytes that
//! are not one of the formats this decodes are four different answers to four
//! different questions, and a reader told "an image was dropped" can act on none
//! of them. The checks run cheapest-and-most-specific first: the mime type is a
//! field, the decoded size is arithmetic (`calcSizeForSlice` refuses what is not
//! base64 without allocating a byte), the size is compared against the cap
//! before the payload is decoded, and the sniff is a handful of comparisons
//! against the bytes that survived all three.

const std = @import("std");
const rpc = @import("protocol.zig");
const Allocator = std.mem.Allocator;

/// The image file formats this client decodes. The list lives here rather than
/// in the decoder because it is a fact about the record - what a payload is,
/// judged from its own bytes - and `gpu/image.zig` answers for it exhaustively:
/// a format added here is a codec that file has to answer for.
pub const Format = enum { png, jpeg, bmp, gif };

/// Why a part that said it was a picture is not one this reader kept, or not one
/// it could draw.
///
/// The first five are decided at capture, by this module; the last three are
/// decided by the drawing side, which is where the pixels - and therefore the
/// cost of getting them - are. They share one vocabulary because a reader is
/// owed one answer: a line that names what an image was and why it is not on
/// screen. Which side decided is visible in the split above and nowhere else,
/// because nothing downstream of the record should have to care.
pub const Refusal = enum {
    /// Kept: the payload decoded into the bytes of a format this reads.
    none,
    /// The `data` field is not base64, including a field that is base64 by
    /// length and not by character. A part whose payload is missing or empty
    /// does not land here: nothing is not "not base64", it is a payload of zero
    /// bytes, and zero bytes are not an image.
    not_base64,
    /// The declared mime type is not one of the formats this client reads. The
    /// payload is not decoded at all: bytes that nothing will draw are not worth
    /// the bound.
    unsupported_mime,
    /// The payload is past `max_image_bytes`, which is decided from its length
    /// before it is decoded, so a part cannot allocate its way past the cap.
    too_many_bytes,
    /// The bytes are not a PNG, a JPEG, a BMP, or a GIF. A part that says
    /// `image/png` over something else is this, and the record keeps the mime
    /// type it declared so the line can say what the agent claimed.
    not_an_image,
    /// The pixels are past what an image may take (`gpu/image.zig` limits the
    /// decode, and a small file can decode to a bitmap far larger than the file).
    too_many_pixels,
    /// The decoder could not make pixels out of bytes a header read as valid.
    undecodable,
    /// The picture space had no room for this one.
    no_room,
};

/// One image part, kept: where it arrived, what it claimed, what it is, and the
/// image file it carried.
pub const Image = struct {
    /// A number that names this picture for as long as the client keeps it, the
    /// same handle a run gets for the same reason: the offset moves when the
    /// transcript trims its front, and an interface that has to name a picture
    /// (a census line, a cache key, a click) needs something that does not.
    seq: usize,
    /// Where in the transcript bytes the part arrived.
    at: usize,
    /// The mime type the part declared, bounded by `max_mime_bytes`. Kept even
    /// when the bytes turn out to be something else, because what an agent
    /// claimed is part of what it sent.
    mime: []const u8,
    /// The format the bytes were recognised as, or null when they were not
    /// recognised at all. This - not the mime type - is what the decoder is
    /// given: the bytes are what they are.
    format: ?Format,
    /// The image file, base64 taken off, owned by the record. Empty when the
    /// record is a refusal: a payload nothing can draw is not worth keeping.
    bytes: []const u8,
    /// How big the payload was, in bytes, whenever that is known - which is
    /// everything except a payload that was never base64. A refusal names it so
    /// a reader can tell a part that carried 2 kB of nothing from one that
    /// carried 40 MB of nothing.
    size: usize,
    /// Why there is nothing to draw, or `.none`.
    refusal: Refusal,
};

/// The most bytes one image may take, base64 taken off.
///
/// A screenshot is the biggest thing an agent sensibly sends, and 2 MiB is a
/// 1920×1080 PNG with room to spare. The bound is on the payload rather than on
/// the pixels because this is where the payload is: the pixel count is decided
/// where the pixels are, by the decoder's own limits.
pub const max_image_bytes: usize = 2 * 1024 * 1024;

/// The most images a client keeps, oldest dropped first. One record per part,
/// so this is a turn's worth of pictures; the transcript itself is bounded at
/// 512 KiB, and a session that sends more than 32 images is a session whose
/// first images a reader has scrolled past.
pub const max_images: usize = 32;

/// The most bytes a declared mime type may take. A mime type is a short token
/// rather than content, so a "mime type" past this is not kept in part: the
/// comparison against the ones we read cannot match anyway.
pub const max_mime_bytes: usize = 64;

/// The base64 characters of a payload that could still decode to
/// `max_image_bytes`: four characters carry three bytes, rounded up, plus the
/// padding of the last group.
const max_base64_bytes: usize = std.base64.standard.Encoder.calcSize(max_image_bytes);

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

/// Whether a content block is a picture. This is the one question the client
/// asks a content block before deciding which record it belongs to, which is
/// why it is a function here rather than a comparison written out at each
/// dispatch site.
pub fn isImage(content: rpc.Value) bool {
    return std.mem.eql(u8, rpc.str(content, "type"), "image");
}

/// Whether a declared mime type is one of the formats this client reads.
///
/// A mime type is case-insensitive, so `Image/PNG` means what `image/png`
/// means, and `image/jpg` is accepted beside `image/jpeg` because agents send
/// it and it names the same codec. Nothing else is accepted: a mime type is the
/// agent's own statement about its payload, and decoding a format this does not
/// claim to read is how a client ends up owning a decoder it never chose.
pub fn handled(mime: []const u8) bool {
    const read = [_][]const u8{ "image/png", "image/jpeg", "image/jpg", "image/bmp", "image/gif" };
    for (read) |type_name| {
        if (std.ascii.eqlIgnoreCase(mime, type_name)) return true;
    }
    return false;
}

/// Which of the four formats a payload is, from the payload's own first bytes.
///
/// The bytes decide, and the mime type is only what the agent said: a part that
/// claims `image/png` over a JPEG is not a reason to refuse, it is a reason to
/// decode a JPEG. Bytes that match nothing are the one case this cannot guess
/// at, and they are refused by name rather than handed to a decoder that would
/// fail at something less useful to say.
pub fn formatOf(bytes: []const u8) ?Format {
    if (std.mem.startsWith(u8, bytes, &png_signature)) return .png;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return .gif;
    // A BMP starts with `BM`, the shortest of the four signatures by a long way,
    // which is why it is checked last: two bytes are easy to match by accident.
    if (std.mem.startsWith(u8, bytes, "BM")) return .bmp;
    return null;
}

/// Keep one image part: the payload decoded, or the record that says why not.
///
/// The caller owns the record and gives it back with `deinit`. Placement and
/// the handle are the caller's, for the same reason `stream.begin` leaves them
/// to the client: where a part belongs is a fact about the transcript, and the
/// transcript is the client's.
pub fn capture(a: Allocator, content: rpc.Value, at: usize, seq: usize) !Image {
    const declared = rpc.str(content, "mimeType");
    var record: Image = .{
        .seq = seq,
        .at = at,
        .mime = &.{},
        .format = null,
        .bytes = &.{},
        .size = 0,
        .refusal = .none,
    };
    const name = declared[0..@min(declared.len, max_mime_bytes)];
    if (name.len != 0) record.mime = try a.dupe(u8, name);
    errdefer if (record.mime.len != 0) a.free(record.mime);

    if (!handled(name)) {
        record.refusal = .unsupported_mime;
        return record;
    }
    const data = rpc.str(content, "data");
    // The decoded size is known without decoding, and a payload that is not
    // base64 fails here rather than at the allocation below - so the cap is
    // decided before anything is allocated for the payload.
    const size = std.base64.standard.Decoder.calcSizeForSlice(data) catch {
        record.refusal = .not_base64;
        return record;
    };
    record.size = size;
    if (data.len > max_base64_bytes or size > max_image_bytes) {
        record.refusal = .too_many_bytes;
        return record;
    }
    const bytes = try a.alloc(u8, size);
    errdefer a.free(bytes);
    std.base64.standard.Decoder.decode(bytes, data) catch {
        // The length and the padding were base64 and the characters were not,
        // which is the same fact as far as a reader is concerned.
        a.free(bytes);
        record.refusal = .not_base64;
        return record;
    };
    record.format = formatOf(bytes) orelse {
        a.free(bytes);
        record.refusal = .not_an_image;
        return record;
    };
    record.bytes = bytes;
    return record;
}

/// Move every recorded offset up by the bytes that just left the front of the
/// transcript, which is `stream.shiftAt` and `tool_call.shiftAt` for pictures:
/// an offset is a position in those bytes whichever kind of record holds it,
/// and the client calls all three from one place so a later reader cannot fix
/// one and miss the others.
pub fn shiftAt(images: []Image, dropped: usize) void {
    for (images) |*record| record.at = record.at -| dropped;
}

/// Release a record: its mime type and its payload are freed and the record is
/// emptied, so releasing one twice is a no-op rather than a fault.
pub fn deinit(record: *Image, a: Allocator) void {
    if (record.bytes.len != 0) a.free(record.bytes);
    if (record.mime.len != 0) a.free(record.mime);
    record.* = .{
        .seq = 0,
        .at = 0,
        .mime = &.{},
        .format = null,
        .bytes = &.{},
        .size = 0,
        .refusal = .none,
    };
}

/// The PNG the tests below and the mock harness both send: sixteen pixels
/// square, four quadrants of distinct colour and a white diagonal, small enough
/// to write down and structured enough that a drawing of it is unmistakable.
/// The fixture in `tools/mock_agent.py` carries the same bytes.
pub const sample_png_base64 =
    "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAYUlEQVR42p3M0QkAIQyD4Q6WSW4SR3SIG8INPAQFkZpLG/jfwmd97gXcUB+ajRNDJIAhMnBDQoCHhIETSQE7kgZUxFBaZ621CrdfYJwYIgEMkYEbEgI8JAycSArYkTSwkA91yLusbERALAAAAABJRU5ErkJggg==";

test "an image part is kept as the file it carried, placed where it arrived" {
    const a = std.testing.allocator;
    var buffer: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(&buffer, "{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/png\"}}", .{sample_png_base64});
    const content = try std.json.parseFromSlice(rpc.Value, a, json, .{});
    defer content.deinit();
    var record = try capture(a, content.value, 40, 7);
    defer deinit(&record, a);

    // The mime type as it arrived, and the format the bytes really are.
    try std.testing.expectEqualStrings("image/png", record.mime);
    try std.testing.expectEqual(Format.png, record.format.?);
    try std.testing.expectEqual(Refusal.none, record.refusal);
    // base64 is transport: what is kept is the image file, and it is the file
    // the fixture sends rather than the text that carried it.
    try std.testing.expect(record.bytes.len > 0);
    try std.testing.expectEqual(record.bytes.len, record.size);
    try std.testing.expect(std.mem.startsWith(u8, record.bytes, &png_signature));
    // Where it arrived, and the handle that names it: the interface draws a
    // picture at its offset and nothing else in the record can name it.
    try std.testing.expectEqual(@as(usize, 40), record.at);
    try std.testing.expectEqual(@as(usize, 7), record.seq);
}

test "a payload that is not base64 is refused without decoding it" {
    const a = std.testing.allocator;
    const content = try std.json.parseFromSlice(rpc.Value, a, "{\"type\":\"image\",\"data\":\"not base64!!\",\"mimeType\":\"image/png\"}", .{});
    defer content.deinit();
    var record = try capture(a, content.value, 0, 1);
    defer deinit(&record, a);
    try std.testing.expectEqual(Refusal.not_base64, record.refusal);
    try std.testing.expect(record.bytes.len == 0);
    try std.testing.expect(record.format == null);

    // A part that declares an image and carries no payload at all is refused by
    // the bytes rather than by the base64: nothing is not "not base64", it is a
    // payload of zero bytes, and zero bytes are not an image. The size is zero
    // and named, so the line says a part arrived empty rather than looking like
    // a decoder failure.
    const empty = try std.json.parseFromSlice(rpc.Value, a, "{\"type\":\"image\",\"mimeType\":\"image/png\"}", .{});
    defer empty.deinit();
    var nothing = try capture(a, empty.value, 0, 2);
    defer deinit(&nothing, a);
    try std.testing.expectEqual(Refusal.not_an_image, nothing.refusal);
    try std.testing.expectEqual(@as(usize, 0), nothing.size);
}

test "a mime type this client does not read is its own answer" {
    const a = std.testing.allocator;
    const content = try std.json.parseFromSlice(rpc.Value, a, "{\"type\":\"image\",\"data\":\"aGk=\",\"mimeType\":\"image/webp\"}", .{});
    defer content.deinit();
    var record = try capture(a, content.value, 0, 1);
    defer deinit(&record, a);
    // Refused by the mime type before anything is decoded, and the mime type is
    // kept so the line can name what the agent claimed.
    try std.testing.expectEqual(Refusal.unsupported_mime, record.refusal);
    try std.testing.expectEqualStrings("image/webp", record.mime);
    try std.testing.expectEqual(@as(usize, 0), record.size);

    // The formats this client does read are read whatever case they are sent in.
    try std.testing.expect(handled("image/PNG"));
    try std.testing.expect(handled("image/jpg"));
    try std.testing.expect(!handled("image/svg+xml"));
    try std.testing.expect(!handled(""));
}

test "a payload past the cap is refused before it is decoded" {
    const a = std.testing.allocator;
    // A base64 payload whose length implies more than an image may take, built
    // rather than written down.
    const data = try a.alloc(u8, max_base64_bytes + 4);
    defer a.free(data);
    @memset(data, 'A');
    const json = try std.fmt.allocPrint(a, "{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/png\"}}", .{data});
    defer a.free(json);
    const content = try std.json.parseFromSlice(rpc.Value, a, json, .{});
    defer content.deinit();

    // The allocator fails after its first allocation, so a capture that decoded
    // the payload in order to measure it would come back as an allocation
    // failure rather than as an answer: the cap is decided before the bytes are
    // taken.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    var record = try capture(failing.allocator(), content.value, 0, 1);
    defer deinit(&record, failing.allocator());
    try std.testing.expectEqual(Refusal.too_many_bytes, record.refusal);
    try std.testing.expect(record.bytes.len == 0);
    // The size is known and named, which is what tells a reader whether a part
    // was twice the cap or a thousand times it.
    try std.testing.expect(record.size > max_image_bytes);
}

test "bytes that are not one of the four formats are refused by name" {
    const a = std.testing.allocator;
    // The payload the harness used to send: `aGk=`, two bytes that are not a
    // PNG. It is valid base64, so the answer is about the bytes.
    const content = try std.json.parseFromSlice(rpc.Value, a, "{\"type\":\"image\",\"data\":\"aGk=\",\"mimeType\":\"image/png\"}", .{});
    defer content.deinit();
    var record = try capture(a, content.value, 0, 1);
    defer deinit(&record, a);
    try std.testing.expectEqual(Refusal.not_an_image, record.refusal);
    try std.testing.expectEqual(@as(usize, 2), record.size);
    try std.testing.expect(record.bytes.len == 0);
    try std.testing.expect(record.format == null);
}

test "the bytes are what the payload is, not what the mime type claims" {
    const a = std.testing.allocator;
    var buffer: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(&buffer, "{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}}", .{sample_png_base64});
    const content = try std.json.parseFromSlice(rpc.Value, a, json, .{});
    defer content.deinit();
    var record = try capture(a, content.value, 0, 3);
    defer deinit(&record, a);
    // A claim that does not match its payload is not a refusal - the bytes are
    // a PNG and a PNG is a format this reads. The claim is kept anyway, because
    // the line that names the picture is about what the agent sent.
    try std.testing.expectEqual(Format.png, record.format.?);
    try std.testing.expectEqualStrings("image/jpeg", record.mime);
    try std.testing.expectEqual(Refusal.none, record.refusal);
}

test "the four signatures are recognised and nothing else is" {
    try std.testing.expectEqual(Format.png, formatOf(&png_signature).?);
    try std.testing.expectEqual(Format.jpeg, formatOf("\xff\xd8\xff\xe0").?);
    try std.testing.expectEqual(Format.gif, formatOf("GIF87a").?);
    try std.testing.expectEqual(Format.gif, formatOf("GIF89a...").?);
    try std.testing.expectEqual(Format.bmp, formatOf("BM\x36\x00").?);
    try std.testing.expectEqual(@as(?Format, null), formatOf(""));
    try std.testing.expectEqual(@as(?Format, null), formatOf("hi"));
    // A prefix of a signature is not a signature.
    try std.testing.expectEqual(@as(?Format, null), formatOf("\x89PN"));
}

test "a picture's offset moves up by what the transcript dropped" {
    const a = std.testing.allocator;
    const content = try std.json.parseFromSlice(rpc.Value, a, "{\"type\":\"image\",\"mimeType\":\"image/webp\"}", .{});
    defer content.deinit();
    var records = [_]Image{
        try capture(a, content.value, 500, 1),
        try capture(a, content.value, 8, 2),
    };
    defer for (&records) |*record| deinit(record, a);
    shiftAt(&records, 12);
    // One moves up with the drop, and one that was nearer than the drop lands
    // at the front rather than wrapping to the wrong end.
    try std.testing.expectEqual(@as(usize, 488), records[0].at);
    try std.testing.expectEqual(@as(usize, 0), records[1].at);
    shiftAt(&records, 4096);
    try std.testing.expectEqual(@as(usize, 0), records[0].at);
}
