//! A run of session text, read out of the chunks ACP delivers it in.
//!
//! Three of the updates a session sends are streams rather than messages: the
//! agent's reasoning (`agent_thought_chunk`), what the user said
//! (`user_message_chunk`), and the summary an agent writes when it folds its
//! context (`compaction_summary_chunk`). Each arrives as hundreds of small
//! chunks, and a transcript with hundreds of entries for one thought is not a
//! transcript. So the chunks of one run accumulate into a single record, and
//! that record carries `at`: the transcript offset the run began at. That is
//! where the interface draws it, which is what puts reasoning where it happened
//! rather than at the end - the same offset, for the same reason, that
//! `tool_call.zig` gives a call.
//!
//! Nothing here is unbounded. A single chunk past `max_chunk_bytes` is refused
//! by name; a run that reaches `max_stream_bytes` keeps the bytes that fit,
//! says how many it dropped, and takes no more. Reasoning runs to tens of
//! thousands of tokens, and the point of keeping it is that a reader can look
//! at it, not that we archive it: 64 KiB is the first ~16k tokens, which is a
//! look, and a session that reasons for an hour cannot grow a record past that.

const std = @import("std");
const rpc = @import("protocol.zig");
/// A picture is a content block this module has to recognise and leave alone:
/// see `feed`, which would otherwise count one as a part nothing could read.
/// Named `image_part` rather than `image` because a helper or a test here has
/// local variables that are an image - the block itself - and Zig refuses a
/// local that shadows a container declaration.
const image_part = @import("image.zig");
const Allocator = std.mem.Allocator;

/// Which run of chunks a record holds. Chunks of one channel accumulate with
/// each other and with nothing else, so the same channel after an interruption
/// is a second record rather than a continuation of the first.
pub const Channel = enum {
    /// `agent_thought_chunk`: the agent's reasoning, which no other part of the
    /// protocol carries and which used to be thrown away here.
    thought,
    /// `user_message_chunk`: what the user said, as a session replays a turn.
    user,
    /// `compaction_summary_chunk`: the summary an agent writes when it folds
    /// its context.
    summary,
};

/// One run of chunks: what was said, where it belongs, and whether it is still
/// arriving.
pub const Stream = struct {
    channel: Channel,
    /// A number that names this run for as long as the client keeps it. The
    /// agent gives a compaction an id and a thought nothing at all, and the two
    /// other things a run has - its offset and its text - move: the transcript
    /// trims its front, and the text arrives. An interface that lets a reader
    /// open one run and shut another needs a handle that none of that changes,
    /// which is this: the client hands out the next one as the run begins.
    seq: usize,
    /// The agent's id for the run, when it gives one: a compaction names
    /// itself, so the chunks of its summary and the completed summary that
    /// replaces them land on the same record. A thought is anonymous.
    key: []const u8,
    /// Everything the run has said, already concatenated.
    text: []const u8,
    /// Where in the transcript bytes the run began.
    at: usize,
    /// Whether chunks are still arriving. An interface pulses a label while
    /// this is true, which is the whole difference between an agent that is
    /// thinking and one that has stopped.
    streaming: bool,
    /// Whether the run reached `max_stream_bytes`. What did not fit is dropped
    /// rather than held, and `dropped_bytes` says how much.
    truncated: bool,
    /// How many bytes the bound left out. The record says so out loud, because
    /// a reader who cannot see that text continues reads a cut as the whole.
    dropped_bytes: usize,
    /// How many chunks went into the text.
    chunks: usize,
    /// How many parts carried something this client keeps nowhere - a resource
    /// link, or a kind of part this version does not know. Counted rather than
    /// passed over in silence, because a part is still a part of what the agent
    /// sent. A picture is not one of them: an image part is kept as a record of
    /// its own (`image.zig`), so it is not counted here as unread.
    other_parts: usize,
};

/// The most runs a client keeps. One record per run rather than per chunk, so
/// this is a session's worth of thinking rather than a turn's, and the oldest
/// goes first: 128 runs at the per-run bound is a ceiling of 8 MiB, which is
/// the price of never losing the reason a turn went the way it did.
pub const max_streams: usize = 128;

/// The most bytes one run may hold. A stream is cut, not refused, at this
/// point: see the note at the top of the file.
pub const max_stream_bytes: usize = 64 * 1024;

/// The most bytes one chunk may carry. Chunks are a few words each, so a
/// "chunk" past this is not one and is refused by name rather than appended.
pub const max_chunk_bytes: usize = 32 * 1024;

/// The most bytes a run's key may take. A key is an opaque id, not content.
pub const max_key_bytes: usize = 128;

/// Open a record for a run that is starting. The caller owns it and gives it
/// back with `deinit`; the text arrives through `feed` or `replace`.
pub fn begin(a: Allocator, channel: Channel, key: []const u8, at: usize, seq: usize) !Stream {
    const name = key[0..@min(key.len, max_key_bytes)];
    return .{
        .channel = channel,
        .seq = seq,
        .key = if (name.len == 0) &.{} else try a.dupe(u8, name),
        .text = &.{},
        .at = at,
        .streaming = true,
        .truncated = false,
        .dropped_bytes = 0,
        .chunks = 0,
        .other_parts = 0,
    };
}

/// The record a chunk belongs to: the newest one, when it is the same run and
/// is still open. `null` says this chunk begins a run of its own, which is what
/// makes the same channel after an interruption a second record.
///
/// Only the newest record can be open - a run is closed before another begins -
/// so looking at the end of the list is looking at all of them.
pub fn open(streams: []const Stream, channel: Channel, key: []const u8) ?usize {
    if (streams.len == 0) return null;
    const last = streams[streams.len - 1];
    if (!last.streaming or last.channel != channel) return null;
    if (!std.mem.eql(u8, last.key, key)) return null;
    return streams.len - 1;
}

/// End the run that is open. A stream is what arrives with nothing in between,
/// so any update of another kind closes it: an interface that keeps pulsing a
/// label after the thinking stopped is telling a reader the agent is busy when
/// it is not.
pub fn finishOpen(streams: []Stream) void {
    if (streams.len == 0) return;
    streams[streams.len - 1].streaming = false;
}

/// Whether a chunk says nothing: nothing at all, or whitespace. A chunk like
/// that does not open a record, or a turn with a stray newline in it would grow
/// one record that says nothing on every turn.
pub fn blank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

/// The text a content block carries, or nothing when it carries none: an image,
/// a resource link, and a block with no text are all like this.
pub fn textOf(content: rpc.Value) []const u8 {
    return rpc.str(content, "text");
}

/// Add one content block to the run. A text block is appended; a block of
/// another type is counted, because it is part of what the agent sent even
/// though there are no words in it.
///
/// A picture is the one block that is not counted here, because it is not a
/// block this run could not read: the client keeps it as a record of its own
/// (`image.zig`), placed where it arrived, and the counting below is for what
/// nothing keeps at all. Counting an image here as well would tell a reader a
/// part was dropped when it was kept.
pub fn feed(record: *Stream, a: Allocator, content: rpc.Value) !void {
    const text = textOf(content);
    if (text.len != 0) return write(record, a, text);
    if (image_part.isImage(content)) return;
    const kind = rpc.str(content, "type");
    if (kind.len != 0 and !std.mem.eql(u8, kind, "text")) record.other_parts += 1;
}

/// Append text to the run, bounded by `max_stream_bytes`.
///
/// Past the bound the record keeps what fits, counts what did not, and returns
/// `error.StreamTooLarge`: the caller's job is to leave the run open so the
/// rest of the stream falls on the floor of the same record rather than opening
/// one record per chunk. A chunk past `max_chunk_bytes` is `error.ChunkTooLarge`
/// and is not appended at all.
pub fn write(record: *Stream, a: Allocator, text: []const u8) !void {
    if (text.len > max_chunk_bytes) return error.ChunkTooLarge;
    const room = max_stream_bytes -| record.text.len;
    const kept = if (record.truncated) 0 else @min(text.len, room);
    const over = text.len - kept;
    record.dropped_bytes += over;
    if (over != 0) record.truncated = true;
    if (kept != 0) {
        const combined = try std.mem.concat(a, u8, &.{ record.text, text[0..kept] });
        if (record.text.len != 0) a.free(record.text);
        record.text = combined;
        record.chunks += 1;
    }
    if (over != 0) return error.StreamTooLarge;
}

/// Replace the run's text with a complete one. A compaction's `summary` is the
/// whole summary rather than one more chunk of it, so it replaces what the
/// chunks had accumulated instead of doubling it.
pub fn replace(record: *Stream, a: Allocator, blocks: []const rpc.Value) !void {
    var held: std.ArrayList(u8) = .empty;
    defer held.deinit(a);
    var dropped: usize = 0;
    for (blocks) |block| {
        const part = textOf(block);
        if (part.len == 0) continue;
        const room = max_stream_bytes -| held.items.len;
        if (held.items.len != 0 and room != 0) try held.append(a, '\n');
        var kept = @min(part.len, max_stream_bytes -| held.items.len);
        // Never cut a character in half: the next byte starts one.
        while (kept < part.len and part[kept] & 0xc0 == 0x80) : (kept += 1) {}
        try held.appendSlice(a, part[0..kept]);
        dropped += part.len - kept;
    }
    const owned = try a.dupe(u8, held.items);
    if (record.text.len != 0) a.free(record.text);
    record.text = owned;
    record.dropped_bytes += dropped;
    if (dropped != 0) record.truncated = true;
    if (dropped != 0) return error.StreamTooLarge;
}

/// Release a record: its text and its key are freed and the record is emptied,
/// so releasing one twice is a no-op rather than a fault.
pub fn deinit(record: *Stream, a: Allocator) void {
    if (record.text.len != 0) a.free(record.text);
    if (record.key.len != 0) a.free(record.key);
    record.* = .{
        .channel = .thought,
        .seq = 0,
        .key = &.{},
        .text = &.{},
        .at = 0,
        .streaming = false,
        .truncated = false,
        .dropped_bytes = 0,
        .chunks = 0,
        .other_parts = 0,
    };
}

/// Move every recorded offset up by the bytes that just left the front of the
/// transcript. A transcript is bounded by dropping what is oldest in it, and a
/// recorded offset is a position in those same bytes: leave it alone and a long
/// transcript draws old reasoning on the wrong line. This is `tool_call.shiftAt`
/// for streams, which is to say the same rule for the same kind of position -
/// and the client calls both from one place so a later reader cannot fix one
/// and miss the other.
pub fn shiftAt(streams: []Stream, dropped: usize) void {
    for (streams) |*record| record.at = record.at -| dropped;
}

// One run, from chunks to a record: the text is the run's words in order, the
// offset is where the run began rather than where it ended, and the label stops
// pulsing when the run does.
test "a run of chunks is one record, placed where it began" {
    const a = std.testing.allocator;
    var held: std.ArrayList(Stream) = .empty;
    defer {
        for (held.items) |*record| deinit(record, a);
        held.deinit(a);
    }

    try held.append(a, try begin(a, .thought, "", 40, 1));
    const first = try std.json.parseFromSlice(rpc.Value, a, "{\"type\":\"text\",\"text\":\"I should look at \"}", .{});
    defer first.deinit();
    try feed(&held.items[0], a, first.value);
    const second = try std.json.parseFromSlice(rpc.Value, a, "{\"type\":\"text\",\"text\":\"the transcript widget.\"}", .{});
    defer second.deinit();
    try feed(&held.items[0], a, second.value);

    try std.testing.expectEqualStrings("I should look at the transcript widget.", held.items[0].text);
    try std.testing.expectEqual(@as(usize, 2), held.items[0].chunks);
    try std.testing.expectEqual(Channel.thought, held.items[0].channel);
    // The offset is the one the run began at: reasoning happened there, and a
    // record that took the offset of its last chunk would be drawn after
    // whatever the thinking was about.
    try std.testing.expectEqual(@as(usize, 40), held.items[0].at);
    try std.testing.expectEqual(@as(usize, 1), held.items[0].seq);
    try std.testing.expect(held.items[0].streaming);
    try std.testing.expectEqual(@as(?usize, 0), open(held.items, .thought, ""));

    // The next update that is not a chunk of this run is what ends it, and the
    // record keeps saying everything it said.
    finishOpen(held.items);
    try std.testing.expect(!held.items[0].streaming);
    try std.testing.expectEqual(@as(?usize, null), open(held.items, .thought, ""));
    try std.testing.expectEqualStrings("I should look at the transcript widget.", held.items[0].text);
}

test "another channel or another key is another run" {
    const a = std.testing.allocator;
    var records = [_]Stream{try begin(a, .thought, "", 10, 1)};
    defer {
        for (&records) |*record| deinit(record, a);
    }
    // The run is open and the channel matches, so the chunk belongs to it.
    try std.testing.expectEqual(@as(?usize, 0), open(&records, .thought, ""));
    // Another channel is another run, and so is another key of the same
    // channel: the summary of a second compaction is not the first one's.
    try std.testing.expectEqual(@as(?usize, null), open(&records, .user, ""));
    try std.testing.expectEqual(@as(?usize, null), open(&records, .summary, "c1"));
}

test "a chunk past a chunk's bound is refused, and a run at its bound keeps what fits" {
    const a = std.testing.allocator;
    var record = try begin(a, .thought, "c1", 0, 7);
    defer deinit(&record, a);
    try std.testing.expectEqualStrings("c1", record.key);

    const oversized = try a.alloc(u8, max_chunk_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.ChunkTooLarge, write(&record, a, oversized));
    try std.testing.expectEqualStrings("", record.text);
    try std.testing.expectEqual(@as(usize, 0), record.chunks);

    // A run that reaches the bound keeps the bytes that fit and says how many
    // it left out: refusing the whole of it would throw away the reasoning that
    // does fit to punish the part that does not.
    const half = try a.alloc(u8, max_stream_bytes / 2);
    defer a.free(half);
    @memset(half, 'r');
    try write(&record, a, half);
    try std.testing.expectEqualStrings(half, record.text);
    try write(&record, a, half);
    try std.testing.expectEqual(max_stream_bytes, record.text.len);
    try std.testing.expect(!record.truncated);
    try std.testing.expectEqual(@as(usize, 2), record.chunks);

    const rest = "and the reasoning that does not fit";
    try std.testing.expectError(error.StreamTooLarge, write(&record, a, rest));
    try std.testing.expectEqual(max_stream_bytes, record.text.len);
    try std.testing.expect(record.truncated);
    try std.testing.expectEqual(rest.len, record.dropped_bytes);

    // Past the bound the record takes nothing more, and the dropping is still
    // counted, so the cut is honest rather than silent.
    try std.testing.expectError(error.StreamTooLarge, write(&record, a, "and more"));
    try std.testing.expectEqual(max_stream_bytes, record.text.len);
    try std.testing.expectEqual(rest.len + "and more".len, record.dropped_bytes);
    try std.testing.expectEqual(@as(usize, 2), record.chunks);
}

test "a part with no text is counted and a chunk that says nothing is blank" {
    const a = std.testing.allocator;
    var record = try begin(a, .thought, "", 0, 3);
    defer deinit(&record, a);
    // Nothing at all is not a thought: it must not open a record, and it must
    // not count as a part either.
    try std.testing.expect(blank(""));
    try std.testing.expect(blank("\n \t\r\n"));
    try std.testing.expect(!blank("wait"));
    const empty = try std.json.parseFromSlice(rpc.Value, a, "{}", .{});
    defer empty.deinit();
    try feed(&record, a, empty.value);
    try std.testing.expectEqual(@as(usize, 0), record.chunks);
    try std.testing.expectEqual(@as(usize, 0), record.other_parts);
    // A picture is part of the run and is not counted as one of its unreadable
    // parts: the client keeps it as a record of its own, placed where it
    // arrived, and counting it here as well would say a part was dropped when
    // it was kept.
    const image = try std.json.parseFromSlice(rpc.Value, a,
        \\{"type":"image","data":"aGk=","mimeType":"image/png"}
    , .{});
    defer image.deinit();
    try feed(&record, a, image.value);
    try std.testing.expectEqual(@as(usize, 0), record.other_parts);
    try std.testing.expectEqualStrings("", record.text);
    // A part of another type is part of the run, and a reader is told there was
    // one rather than being shown a stream that is quietly short.
    const link = try std.json.parseFromSlice(rpc.Value, a,
        \\{"type":"resource_link","uri":"file:///tmp/notes.md","name":"notes"}
    , .{});
    defer link.deinit();
    try feed(&record, a, link.value);
    try std.testing.expectEqual(@as(usize, 1), record.other_parts);
    try std.testing.expectEqualStrings("", record.text);
}

test "a complete summary replaces the chunks that arrived before it" {
    const a = std.testing.allocator;
    var record = try begin(a, .summary, "c1", 7, 8);
    defer deinit(&record, a);
    try write(&record, a, "half a sum");
    try std.testing.expectEqualStrings("half a sum", record.text);
    const blocks = try std.json.parseFromSlice(rpc.Value, a,
        \\[{"type":"text","text":"the whole summary"},{"type":"text","text":"in two parts"}]
    , .{});
    defer blocks.deinit();
    try replace(&record, a, blocks.value.array.items);
    try std.testing.expectEqualStrings("the whole summary\nin two parts", record.text);
    try std.testing.expect(!record.truncated);
    // The run keeps its channel and its offset: replacing the words is not
    // moving what happened.
    try std.testing.expectEqual(Channel.summary, record.channel);
    try std.testing.expectEqual(@as(usize, 7), record.at);
}

test "an offset moves up by what the transcript dropped" {
    const a = std.testing.allocator;
    var records = [_]Stream{
        try begin(a, .thought, "", 500, 1),
        try begin(a, .user, "", 40, 2),
    };
    defer for (&records) |*record| deinit(record, a);
    shiftAt(&records, 300);
    // A record that landed before the drop lands at the front, where it
    // belongs, rather than wrapping to a position past the end.
    try std.testing.expectEqual(@as(usize, 200), records[0].at);
    try std.testing.expectEqual(@as(usize, 0), records[1].at);
    shiftAt(&records, 10_000);
    try std.testing.expectEqual(@as(usize, 0), records[0].at);
}
