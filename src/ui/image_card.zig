//! A picture, as the transcript draws it: how big it is drawn, and the line that
//! names it.
//!
//! Two questions, and both belong to the interface rather than to the record. A
//! record knows what arrived; only the panel knows how much room it has, so the
//! size a picture is drawn at is decided here, from the size the decoder found
//! and the box the row leaves. And a picture whose pixels never arrived - refused
//! by a bound, or by a decoder - has no other way of being read: the line is what
//! a reader gets instead, so it says what the image was and exactly why it is not
//! there. Colour and glyphs are the drawer's; the words are this module's.
//!
//! Nothing here touches a texture, and nothing here decodes: a `Fit` is
//! arithmetic, and a label is text. That is what lets the whole vocabulary of
//! "what an image is, and what became of it" be read by a test with no renderer
//! in it.

const std = @import("std");
const acp_image = @import("../acp/image.zig");
const gpu_image = @import("../gpu/image.zig");
const stream_card = @import("stream_card.zig");
const Allocator = std.mem.Allocator;

pub const Image = acp_image.Image;
pub const Refusal = acp_image.Refusal;
pub const Format = acp_image.Format;

/// How wide and tall a picture is drawn, in the same units the panel measures
/// in.
pub const Fit = struct { width: f32, height: f32 };

/// The most rows one picture may take.
///
/// This is the shape of "it does not fit": a picture is drawn as wide as the
/// panel, and a tall one would otherwise be a screenful with nothing else on it.
/// Twenty rows is about a third of the dock, which is enough for a screenshot to
/// be read as one and leaves the transcript around it visible.
pub const max_rows: usize = 20;

/// What the drawing did with a record, in the terms both the row and the census
/// need: the size the decoder found and the size it was drawn at, or the reason
/// there is nothing to draw.
///
/// It is an outcome rather than a fact about the record because only the frame
/// that drew it knows: a decode can refuse pixels a capture was happy to keep,
/// and a picture space can be full. Null is the honest answer for a record
/// nothing has tried to draw yet.
pub const Outcome = union(enum) {
    drawn: struct { width: u32, height: u32, fit: Fit },
    refused: Refusal,
};

/// The box one picture is drawn in, fitted to what the row has.
///
/// Two rules, and the second is the one worth stating. The aspect ratio is the
/// invariant: a picture is never stretched to fill a shape, because a stretched
/// picture lies about what it shows. And a picture is never *enlarged*: a
/// screenshot wider than the dock is scaled down until it fits, and a sixteen
/// pixel drawing is drawn sixteen pixels wide. Blowing it up would invent detail
/// the agent did not send, and a blurry smudge that eats a third of the dock is
/// a worse answer than a small clear one - the line beside it names the size it
/// was written at, so a reader is told what they are looking at either way.
///
/// The height bound is what a picture that is *tall* is fitted to, which is what
/// keeps one image from being the whole panel.
pub fn fit(natural_w: u32, natural_h: u32, available_w: f32, available_h: f32) Fit {
    if (natural_w == 0 or natural_h == 0) return .{ .width = 0, .height = 0 };
    if (available_w <= 0 or available_h <= 0) return .{ .width = 0, .height = 0 };
    const width: f32 = @floatFromInt(natural_w);
    const height: f32 = @floatFromInt(natural_h);
    const scale = @min(1, @min(available_w / width, available_h / height));
    return .{ .width = @max(1, width * scale), .height = @max(1, height * scale) };
}

/// How many display rows a picture occupies. A picture is drawn from the top of
/// its first row, so this is what tells the row grid how much to reserve - and a
/// fractional row is a whole row, because the line after it has to start below
/// the picture rather than across it.
pub fn rows(fitted: Fit, line_height: f32) usize {
    if (fitted.height <= 0 or line_height <= 0) return 0;
    return @intFromFloat(@ceil(fitted.height / line_height));
}

/// The one line a picture leaves behind: what it is, and what became of it.
///
/// `outcome` is null for a record nothing has drawn yet, which is a thing a
/// census can be asked before a frame has run. A record refused at capture has no
/// outcome at all - nothing ever tries to draw it - and its own refusal is what
/// the line reports.
///
/// The result is the only thing allocated: every number that goes into the line
/// is formatted into a buffer here, because a draw site's allocator is a frame
/// arena and a label with six temporaries in it is six pieces of garbage per
/// frame in the arena a frame's drawing is thrown away with.
pub fn label(record: Image, outcome: ?Outcome, a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    // What the agent said it was. It is the one name a picture always has, even
    // when the bytes turned out to be something else.
    try out.appendSlice(a, if (record.mime.len != 0) record.mime else "image");
    if (whyNot(record, outcome)) |why| {
        try out.appendSlice(a, " · not drawn: ");
        try appendReason(&out, a, record, why);
        return out.toOwnedSlice(a);
    }
    var line: [64]u8 = undefined;
    if (outcome) |drawn| {
        const picture = switch (drawn) {
            .drawn => |picture| picture,
            // `whyNot` has already returned for the other case.
            .refused => unreachable,
        };
        try out.appendSlice(a, try std.fmt.bufPrint(&line, " · {d}×{d}", .{ picture.width, picture.height }));
        try appendSize(&out, a, record.size);
        try out.appendSlice(a, try std.fmt.bufPrint(&line, " · shown {d}×{d}", .{ picture.fit.width, picture.fit.height }));
        return out.toOwnedSlice(a);
    }
    // Kept, and nothing has tried to draw it: a reader is told that rather than
    // being told it was refused, because those are different things.
    try appendSize(&out, a, record.size);
    try out.appendSlice(a, " · not drawn yet");
    return out.toOwnedSlice(a);
}

/// The payload's size, when it is known, as its own part of the line. A record
/// with no size - one whose payload was never base64 - says nothing here rather
/// than saying zero, which would be a fact about the part that is not true.
fn appendSize(out: *std.ArrayList(u8), a: Allocator, size: usize) !void {
    if (size == 0) return;
    var number: [24]u8 = undefined;
    var line: [32]u8 = undefined;
    try out.appendSlice(a, try std.fmt.bufPrint(&line, " · {s}", .{stream_card.sizeText(&number, size)}));
}

/// Why a picture is not on screen: the reason the record carries when it was
/// refused before anything drew it, the reason the drawing found otherwise, and
/// null when it is drawn.
fn whyNot(record: Image, outcome: ?Outcome) ?Refusal {
    if (record.refusal != .none) return record.refusal;
    const drawn = outcome orelse return null;
    return switch (drawn) {
        .drawn => null,
        .refused => |why| why,
    };
}

/// One reason, in the words a reader is owed, appended to the line.
///
/// Each of these is a different thing to do something about - a different agent,
/// a different bound, a different file - so each gets its own sentence rather
/// than one word standing for all of them. Sizes are named where they are known,
/// which is what tells a reader whether a part was twice a bound or a thousand
/// times it.
fn appendReason(out: *std.ArrayList(u8), a: Allocator, record: Image, refusal: Refusal) !void {
    var number: [24]u8 = undefined;
    var limit: [24]u8 = undefined;
    var line: [128]u8 = undefined;
    switch (refusal) {
        // A drawn picture has no reason; this is asked for only when there is
        // something to say.
        .none => {},
        .not_base64 => try out.appendSlice(a, "its payload is not base64"),
        .unsupported_mime => try out.appendSlice(a, try std.fmt.bufPrint(&line, "{s} is not a format this client reads", .{if (record.mime.len != 0) record.mime else "that"})),
        .too_many_bytes => try out.appendSlice(a, try std.fmt.bufPrint(&line, "{s} is past the {s} an image may take", .{
            stream_card.sizeText(&number, record.size),
            stream_card.sizeText(&limit, acp_image.max_image_bytes),
        })),
        .not_an_image => try out.appendSlice(a, try std.fmt.bufPrint(&line, "{s} of something that is not a PNG, JPEG, BMP or GIF", .{stream_card.sizeText(&number, record.size)})),
        // The decoder refuses this from the header, before it inflates
        // anything, so what is known here is the file's size rather than the
        // bitmap's.
        .too_many_pixels => try out.appendSlice(a, try std.fmt.bufPrint(&line, "a {s} image with more pixels than the {d} MP this client decodes", .{
            stream_card.sizeText(&number, record.size),
            gpu_image.max_pixels >> 20,
        })),
        .undecodable => try out.appendSlice(a, "the pixels would not decode"),
        .no_room => try out.appendSlice(a, "the picture space had no room for it"),
    }
}

test "a picture is fitted to the box it has, with its shape kept" {
    // A landscape image taller than the box: the height bound is what it is
    // fitted to, and the width follows from the ratio rather than from the panel.
    const wide = fit(400, 200, 1000, 100);
    try std.testing.expectEqual(@as(f32, 200), wide.width);
    try std.testing.expectEqual(@as(f32, 100), wide.height);
    // A portrait image taller than the box: the width follows the ratio rather
    // than taking the panel's, which is what keeps a picture's shape.
    const tall = fit(100, 2000, 250, 1000);
    try std.testing.expectEqual(@as(f32, 50), tall.width);
    try std.testing.expectEqual(@as(f32, 1000), tall.height);
    // An image that fits the box is drawn at its own size.
    const fits = fit(100, 200, 250, 1000);
    try std.testing.expectEqual(@as(f32, 100), fits.width);
    try std.testing.expectEqual(@as(f32, 200), fits.height);
    // An image that already fits is drawn at its own size: enlarging it would
    // invent detail that is not there, and a 16 pixel drawing is not a 400 pixel
    // picture.
    const small = fit(16, 16, 400, 440);
    try std.testing.expectEqual(@as(f32, 16), small.width);
    try std.testing.expectEqual(@as(f32, 16), small.height);
    // Degenerate input answers rather than dividing: a picture with no pixels,
    // and a row with no room.
    try std.testing.expectEqual(@as(f32, 0), fit(0, 10, 400, 440).width);
    try std.testing.expectEqual(@as(f32, 0), fit(10, 10, 0, 440).width);
    // A very wide image scaled to the panel keeps its ratio rather than being
    // squashed into a square, and a sliver stays a sliver.
    const strip = fit(10000, 100, 400, 440);
    try std.testing.expectEqual(@as(f32, 400), strip.width);
    try std.testing.expectEqual(@as(f32, 4), strip.height);
}

test "a picture's rows are what the next line has to clear" {
    try std.testing.expectEqual(@as(usize, 10), rows(.{ .width = 100, .height = 200 }, 20));
    // A fractional row is a whole row: the line after the picture starts below
    // it rather than halfway through it.
    try std.testing.expectEqual(@as(usize, 11), rows(.{ .width = 100, .height = 201 }, 20));
    try std.testing.expectEqual(@as(usize, 0), rows(.{ .width = 100, .height = 0 }, 20));
    // A picture smaller than one line still occupies one: the line after it has
    // to start below it.
    try std.testing.expectEqual(@as(usize, 1), rows(.{ .width = 16, .height = 16 }, 22));
}

fn sample(refusal: Refusal, size: usize) Image {
    return .{ .seq = 1, .at = 0, .mime = "image/png", .format = if (refusal == .none) .png else null, .bytes = &.{}, .size = size, .refusal = refusal };
}

test "the line names what a picture is and what became of it" {
    const a = std.testing.allocator;
    const drawn = try label(sample(.none, 154), .{ .drawn = .{ .width = 16, .height = 16, .fit = .{ .width = 16, .height = 16 } } }, a);
    defer a.free(drawn);
    try std.testing.expectEqualStrings("image/png · 16×16 · 154 B · shown 16×16", drawn);

    // Kept and not yet drawn: a census can be asked before a frame has run, and
    // "not drawn" and "not drawn yet" are different answers.
    const waiting = try label(sample(.none, 154), null, a);
    defer a.free(waiting);
    try std.testing.expectEqualStrings("image/png · 154 B · not drawn yet", waiting);
}

test "every refusal says its own reason rather than one word for all of them" {
    const a = std.testing.allocator;
    const cases = [_]struct { refusal: Refusal, size: usize, expected: []const u8 }{
        .{ .refusal = .not_base64, .size = 0, .expected = "image/png · not drawn: its payload is not base64" },
        .{ .refusal = .too_many_bytes, .size = 4_200_000, .expected = "image/png · not drawn: 4.2 MB is past the 2.0 MB an image may take" },
        .{ .refusal = .not_an_image, .size = 2, .expected = "image/png · not drawn: 2 B of something that is not a PNG, JPEG, BMP or GIF" },
        .{ .refusal = .too_many_pixels, .size = 1_400_000, .expected = "image/png · not drawn: a 1.4 MB image with more pixels than the 4 MP this client decodes" },
        .{ .refusal = .undecodable, .size = 900, .expected = "image/png · not drawn: the pixels would not decode" },
        .{ .refusal = .no_room, .size = 900, .expected = "image/png · not drawn: the picture space had no room for it" },
    };
    for (cases) |case| {
        const line = try label(sample(case.refusal, case.size), null, a);
        defer a.free(line);
        try std.testing.expectEqualStrings(case.expected, line);
    }
    // A mime type this client does not read is named, so a reader knows what was
    // sent rather than only that it was refused.
    var webp = sample(.unsupported_mime, 0);
    webp.mime = "image/webp";
    const unsupported = try label(webp, null, a);
    defer a.free(unsupported);
    try std.testing.expectEqualStrings("image/webp · not drawn: image/webp is not a format this client reads", unsupported);
}
