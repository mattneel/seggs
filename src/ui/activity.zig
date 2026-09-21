//! What a lane is doing, said in a line.
//!
//! The dock names a lane's state with one word, and `busy` is two different
//! situations wearing that one name: a turn that is streaming and a turn that
//! went quiet forty seconds ago. A reader who cannot tell those apart has to
//! guess whether the agent is working or stuck, and guessing is the whole
//! complaint.
//!
//! This module is a decision and nothing else: facts about a lane go in, and a
//! phase, a line, an indicator and a colour come out. It allocates nothing -
//! the caller passes the buffer the line is written into - and it reads no
//! clock, because the times arrive in `Facts`, and a module that reads the
//! clock cannot be tested. Those two rules are also what make it safe to call
//! from a draw pass, which is where it is called from.
const std = @import("std");
const theme = @import("theme.zig");

/// The situations a lane can be in, in the words a reader sees. `busy` is not
/// one of them: the state the dock reports splits into `starting`, `working`
/// and `stalled`, and telling those apart is this module's reason to exist.
pub const Phase = enum {
    /// Nothing is running and nothing has run.
    offline,
    /// Up and idle, waiting for the reader.
    ready,
    /// A turn has been asked for and nothing has come back yet.
    starting,
    /// A turn is in flight and events are arriving.
    working,
    /// A turn is in flight and nothing has arrived for a while.
    stalled,
    /// The last turn, or the lane itself, failed.
    failed,
};

pub const Facts = struct {
    /// The lane's own word for its state, straight from `Client.State.label()`.
    /// It decides nothing `busy` already decides; it is the tie-break for the
    /// states `busy` collapses, because the lane knows when it is coming up or
    /// cancelling and the reader must not be told `ready` over that.
    state_label: []const u8,
    /// Whether a turn is in flight.
    busy: bool,
    /// Whether the lane is up at all (`Client.State.up()`).
    up: bool,
    /// The last thing that failed, when state is failed. Empty otherwise.
    failure: []const u8 = "",
    /// Milliseconds since the turn was sent. Zero when no turn is in flight.
    since_start_ms: u64 = 0,
    /// Milliseconds since anything at all arrived from the agent. This is the
    /// signal that separates working from stuck, and it is the reason this
    /// module exists.
    since_event_ms: u64 = 0,
    /// What the agent is doing now: a tool call's subject, or a short word for
    /// the current phase. Empty when nothing is known.
    subject: []const u8 = "",
    /// A frame counter the caller owns, used only to move the indicator.
    frame: u64 = 0,
};

pub const Reading = struct {
    phase: Phase,
    /// What the reader glances at, written into the caller's buffer. Owned by
    /// the caller: this module allocates nothing.
    line: []const u8,
    /// A one-character indicator, or empty when nothing should move. It is a
    /// literal, not a slice of `line`, so a one-byte buffer still gets an
    /// indicator even though that buffer holds no line.
    indicator: []const u8,
    color: theme.Color,
};

/// How long a lane may be silent mid-turn before it is reported as stalled.
/// Longer than any call this editor makes takes to answer, and short enough
/// that a reader is not left watching a dead lane for a minute first.
pub const stall_after_ms: u64 = 20_000;

/// How long a turn may be silent before saying so would be a lie: the first
/// second. A prompt that has just gone out has not answered yet by definition,
/// and calling that stalled teaches the reader to ignore the word.
const starting_grace_ms: u64 = 1_000;

/// Read `facts` and say what they mean: which phase the lane is in, the line a
/// reader glances at, the indicator, and the colour to draw both in.
///
/// The line is written into `buf`, which is the caller's; when not even the
/// phase word fits, the line is empty rather than half a word. Nothing here
/// panics: a busy lane with no times, or a subject with no turn, are ordinary
/// inputs and get an ordinary answer.
pub fn read(facts: Facts, buf: []u8) Reading {
    const phase = phaseOf(facts);
    return .{
        .phase = phase,
        .line = lineOf(facts, phase, buf),
        .indicator = indicatorOf(phase, facts.frame),
        .color = colorOf(phase),
    };
}

/// Which of the six situations the facts describe.
///
/// The order of the questions is the order of their certainty. A lane that is
/// not up cannot be working on anything, whatever else its facts claim. Inside
/// a turn, age beats silence: a turn younger than the grace period is never
/// stalled, because a hang needs an age before it is a hang, and that ordering
/// is also what keeps a caller with one stale time - a fresh turn and an old
/// event stamp - from crying wolf.
fn phaseOf(facts: Facts) Phase {
    if (!facts.up) return if (oneLine(facts.failure).len > 0) .failed else .offline;
    if (facts.busy) {
        if (facts.since_start_ms < starting_grace_ms) return .starting;
        if (facts.since_event_ms >= stall_after_ms) return .stalled;
        return .working;
    }
    // Idle with a failure still standing: the lane came back, the turn did not.
    // Saying ready here would be the same guess in a quieter voice, and the
    // caller clears `failure` when it is no longer news.
    if (oneLine(facts.failure).len > 0) return .failed;
    // The lane's own word, for the states the two booleans cannot carry.
    if (labelPhase(facts.state_label)) |phase| return phase;
    return .ready;
}

/// The phase a lane's own label implies while no turn is in flight: `STARTING`
/// is coming up and is not ready to be asked anything, and `WORKING` is
/// cancelling a turn `busy` has already stopped counting. Read case-
/// insensitively, because the words come from `Client.State.label` and the
/// comparison must not depend on how the dock spells them.
fn labelPhase(label: []const u8) ?Phase {
    if (std.ascii.eqlIgnoreCase(label, "STARTING")) return .starting;
    if (std.ascii.eqlIgnoreCase(label, "WORKING")) return .working;
    return null;
}

/// The line a reader glances at.
///
/// The parts are tried richest first, so a small buffer loses the least useful
/// part rather than a word's tail. The subject goes before the time and the
/// time before the word alone, because a reader who can see only one of the
/// three would rather know how long than what - and, for a stalled lane,
/// because the silence is the answer to the question being asked.
fn lineOf(facts: Facts, phase: Phase, buf: []u8) []const u8 {
    const subject = oneLine(facts.subject);
    const reason = oneLine(facts.failure);
    const age = span(facts.since_start_ms);
    const silence = span(facts.since_event_ms);
    return switch (phase) {
        .offline => candidate(buf, "offline", .{}) orelse empty(buf),
        .ready => candidate(buf, "ready", .{}) orelse empty(buf),
        .failed => if (reason.len > 0)
            candidate(buf, "failed · {s}", .{reason}) orelse
                candidate(buf, "failed", .{}) orelse empty(buf)
        else
            candidate(buf, "failed", .{}) orelse empty(buf),
        .starting => if (subject.len > 0)
            candidate(buf, "starting · {s}", .{subject}) orelse
                candidate(buf, "starting", .{}) orelse empty(buf)
        else
            candidate(buf, "starting", .{}) orelse empty(buf),
        .working => if (subject.len > 0)
            candidate(buf, "working · {s} · {d}{s}", .{ subject, age.value, age.unit }) orelse
                candidate(buf, "working · {d}{s}", .{ age.value, age.unit }) orelse
                candidate(buf, "working", .{}) orelse empty(buf)
        else
            candidate(buf, "working · {d}{s}", .{ age.value, age.unit }) orelse
                candidate(buf, "working", .{}) orelse empty(buf),
        // The age rides with the phase word, where it qualifies the stall,
        // while the silence is its own clause at the end: it is the number the
        // reader came for, so it is the last thing dropped. "3m in" cannot be
        // mistaken for the silence beside it the way a bare "3m" could.
        .stalled => if (subject.len > 0)
            candidate(buf, "stalled {d}{s} in · {s} · no word for {d}{s}", .{ age.value, age.unit, subject, silence.value, silence.unit }) orelse
                candidate(buf, "stalled {d}{s} in · no word for {d}{s}", .{ age.value, age.unit, silence.value, silence.unit }) orelse
                candidate(buf, "stalled · no word for {d}{s}", .{ silence.value, silence.unit }) orelse
                candidate(buf, "stalled", .{}) orelse empty(buf)
        else
            candidate(buf, "stalled {d}{s} in · no word for {d}{s}", .{ age.value, age.unit, silence.value, silence.unit }) orelse
                candidate(buf, "stalled · no word for {d}{s}", .{ silence.value, silence.unit }) orelse
                candidate(buf, "stalled", .{}) orelse empty(buf),
    };
}

/// Whether something should move beside the line, and which frame of it.
///
/// Only a turn that is arriving gets a moving indicator. A stalled lane is the
/// one place nothing is happening, so a spinner there would contradict the
/// number printed beside it; `offline`, `failed` and `ready` have nothing under
/// way for the same reason.
fn indicatorOf(phase: Phase, frame: u64) []const u8 {
    return switch (phase) {
        .offline, .ready, .stalled, .failed => "",
        .starting, .working => frames[@intCast(frame % frames.len)..][0..1],
    };
}

/// The four frames the indicator cycles through. ASCII on purpose: the glyph
/// atlas covers what the system font has, and a braille spinner would be a
/// gamble on that font rather than a decision about what to show.
const frames = "|/-\\";

/// The colour each phase is drawn in. Read from the theme's variables at call
/// time rather than copied, so loading a theme repaints this line with
/// everything else.
fn colorOf(phase: Phase) theme.Color {
    return switch (phase) {
        .offline => theme.muted,
        .ready => theme.accent,
        .starting, .working => theme.amber,
        .stalled, .failed => theme.red,
    };
}

/// A length of time in the unit a reader scans: seconds under a minute,
/// minutes under an hour, hours beyond, floored. "42s" at 42.9 seconds is the
/// honest answer to "how long has this been quiet", and 59m59s is nearer
/// fifty-nine minutes than a second short of an hour.
const Span = struct { value: u64, unit: []const u8 };

fn span(ms: u64) Span {
    if (ms < std.time.ms_per_min) return .{ .value = ms / std.time.ms_per_s, .unit = "s" };
    if (ms < std.time.ms_per_hour) return .{ .value = ms / std.time.ms_per_min, .unit = "m" };
    return .{ .value = ms / std.time.ms_per_hour, .unit = "h" };
}

/// The first line of some text, trimmed. A failure reason arrives from an error
/// message and a subject from a tool call, and either may be multi-line, where
/// a reading is one line by definition.
fn oneLine(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and text[end] != '\n' and text[end] != '\r') end += 1;
    return std.mem.trim(u8, text[0..end], " \t");
}

/// Write one candidate line into the caller's buffer, or null when it does not
/// fit. A buffer too small is a legal input rather than an error, so the error
/// `bufPrint` reports for one is the answer to "does this fit".
fn candidate(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    const line = std.fmt.bufPrint(buf, fmt, args) catch return null;
    return line;
}

/// Nothing fits. An empty line rather than half a word: a reader can read
/// nothing, but cannot misread it, and a caller whose buffer is smaller than
/// that word has no room to draw a state anyway.
fn empty(buf: []u8) []const u8 {
    return buf[0..0];
}

const testing = std.testing;

/// A lane that is up and idle, which every test below modifies only in the
/// fields it is about.
const idle = Facts{ .state_label = "READY", .busy = false, .up = true };

test "an idle lane that is up is ready, and nothing moves beside it" {
    var buf: [64]u8 = undefined;
    const reading = read(idle, &buf);
    try testing.expectEqual(Phase.ready, reading.phase);
    try testing.expectEqualStrings("ready", reading.line);
    try testing.expectEqualStrings("", reading.indicator);
    try testing.expectEqual(theme.accent, reading.color);
}

test "the first second of a turn is starting rather than stalled" {
    var buf: [64]u8 = undefined;
    const early = read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 400, .since_event_ms = 400 }, &buf);
    try testing.expectEqual(Phase.starting, early.phase);
    try testing.expectEqualStrings("starting", early.line);
    try testing.expectEqual(theme.amber, early.color);
    try testing.expectEqual(@as(usize, 1), early.indicator.len);

    // The last millisecond of the grace period is still starting; the next one
    // is a turn that has produced nothing, which is working until it stalls.
    const edge = read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 999, .since_event_ms = 999 }, &buf);
    try testing.expectEqual(Phase.starting, edge.phase);
    const begun = read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 1_000, .since_event_ms = 999 }, &buf);
    try testing.expectEqual(Phase.working, begun.phase);
}

test "a working turn says what the agent is doing and how long it has been at it" {
    var buf: [64]u8 = undefined;
    const reading = read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 3_400, .since_event_ms = 120, .subject = "read src/app.zig" }, &buf);
    try testing.expectEqual(Phase.working, reading.phase);
    try testing.expectEqualStrings("working · read src/app.zig · 3s", reading.line);
    try testing.expectEqual(theme.amber, reading.color);
    try testing.expectEqual(@as(usize, 1), reading.indicator.len);

    // Without a subject the line still reads as a sentence: no gap, no
    // separator left dangling where the subject would have been.
    const bare = read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 190_000, .since_event_ms = 400 }, &buf);
    try testing.expectEqualStrings("working · 3m", bare.line);
}

test "a quiet turn is stalled at the threshold and says how long it has been quiet" {
    var buf: [96]u8 = undefined;
    const at = read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 25_000, .since_event_ms = stall_after_ms, .subject = "read src/app.zig" }, &buf);
    try testing.expectEqual(Phase.stalled, at.phase);
    try testing.expectEqualStrings("stalled 25s in · read src/app.zig · no word for 20s", at.line);
    try testing.expectEqual(theme.red, at.color);
    try testing.expectEqualStrings("", at.indicator);

    const past = read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 240_000, .since_event_ms = 2 * std.time.ms_per_min }, &buf);
    try testing.expectEqual(Phase.stalled, past.phase);
    try testing.expectEqualStrings("stalled 4m in · no word for 2m", past.line);

    // A minute of silence at four seconds of turn age still reports the turn's
    // real age: the two numbers answer different questions.
    const quiet_young = read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 4_000, .since_event_ms = 61_000 }, &buf);
    try testing.expectEqualStrings("stalled 4s in · no word for 1m", quiet_young.line);
}

test "a failed lane says what failed, whether the lane is down or up" {
    var buf: [96]u8 = undefined;
    const down = read(.{ .state_label = "OFFLINE", .busy = false, .up = false, .failure = "the agent exited with code 1" }, &buf);
    try testing.expectEqual(Phase.failed, down.phase);
    try testing.expectEqualStrings("failed · the agent exited with code 1", down.line);
    try testing.expectEqual(theme.red, down.color);

    const up = read(.{ .state_label = "READY", .busy = false, .up = true, .failure = "prompt rejected" }, &buf);
    try testing.expectEqual(Phase.failed, up.phase);
    try testing.expectEqualStrings("failed · prompt rejected", up.line);
}

test "a lane that is down is offline, and a reason makes it failed rather than silent" {
    var buf: [96]u8 = undefined;
    const quiet = read(.{ .state_label = "OFFLINE", .busy = false, .up = false }, &buf);
    try testing.expectEqual(Phase.offline, quiet.phase);
    try testing.expectEqualStrings("offline", quiet.line);
    try testing.expectEqual(theme.muted, quiet.color);
    try testing.expectEqualStrings("", quiet.indicator);

    // The lane's word is OFFLINE in both cases, so the reason is the only thing
    // that can tell the reader it crashed; the phase says so too.
    const crashed = read(.{ .state_label = "OFFLINE", .busy = false, .up = false, .failure = "no such binary: claude" }, &buf);
    try testing.expectEqual(Phase.failed, crashed.phase);
    try testing.expectEqualStrings("failed · no such binary: claude", crashed.line);
    try testing.expectEqual(theme.red, crashed.color);
}

test "a lane that calls itself starting or working is never called ready" {
    var buf: [64]u8 = undefined;
    const coming_up = read(.{ .state_label = "STARTING", .busy = false, .up = true }, &buf);
    try testing.expectEqual(Phase.starting, coming_up.phase);
    try testing.expectEqualStrings("starting", coming_up.line);
    try testing.expectEqual(theme.amber, coming_up.color);
    try testing.expectEqual(@as(usize, 1), coming_up.indicator.len);

    // `Client.State.cancelling` reports itself as WORKING with no turn counted.
    const cancelling = read(.{ .state_label = "WORKING", .busy = false, .up = true }, &buf);
    try testing.expectEqual(Phase.working, cancelling.phase);
}

test "the indicator turns while a turn is in flight and stops when nothing moves" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", read(idle, &buf).indicator);
    try testing.expectEqualStrings("", read(.{ .state_label = "OFFLINE", .busy = false, .up = false }, &buf).indicator);
    try testing.expectEqualStrings("", read(.{ .state_label = "OFFLINE", .busy = false, .up = false, .failure = "gone" }, &buf).indicator);
    try testing.expectEqualStrings("", read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 60_000, .since_event_ms = 60_000 }, &buf).indicator);

    var frame: u64 = 0;
    while (frame < 8) : (frame += 1) {
        const reading = read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 5_000, .since_event_ms = 100, .frame = frame }, &buf);
        try testing.expectEqual(@as(usize, 1), reading.indicator.len);
        try testing.expectEqual(frames[@intCast(frame % frames.len)], reading.indicator[0]);
        try testing.expect(std.ascii.isPrint(reading.indicator[0]));
    }
}

test "the same turn reads differently before and after it goes quiet" {
    var working_buf: [96]u8 = undefined;
    var stalled_buf: [96]u8 = undefined;
    // One turn, one fact changed: how long since the agent last said anything.
    var facts = Facts{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 45_000, .since_event_ms = 300, .subject = "read src/app.zig" };
    const working = read(facts, &working_buf);
    facts.since_event_ms = 45_000;
    const stalled = read(facts, &stalled_buf);

    try testing.expectEqual(Phase.working, working.phase);
    try testing.expectEqual(Phase.stalled, stalled.phase);
    try testing.expectEqualStrings("working · read src/app.zig · 45s", working.line);
    try testing.expectEqualStrings("stalled 45s in · read src/app.zig · no word for 45s", stalled.line);
    try testing.expect(!std.mem.eql(u8, working.line, stalled.line));
    try testing.expect(!std.mem.eql(u8, working.indicator, stalled.indicator));
    try testing.expect(working.color[0] != stalled.color[0] or working.color[1] != stalled.color[1]);
}

test "a small buffer drops the subject before the time and the time before the word" {
    const facts = Facts{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 300_000, .since_event_ms = 100, .subject = "read src/app.zig" };
    const full = "working · read src/app.zig · 5m";

    var roomy: [64]u8 = undefined;
    const whole = read(facts, &roomy);
    try testing.expectEqualStrings(full, whole.line);

    var subject_size: [full.len]u8 = undefined;
    try testing.expectEqualStrings(full, read(facts, &subject_size).line);

    var tight: [full.len - 1]u8 = undefined;
    const without_subject = read(facts, &tight);
    try testing.expectEqualStrings("working · 5m", without_subject.line);
    try testing.expect(without_subject.line.len <= tight.len);
    try testing.expect(@intFromPtr(without_subject.line.ptr) >= @intFromPtr(&tight) and
        @intFromPtr(without_subject.line.ptr) + without_subject.line.len <= @intFromPtr(&tight) + tight.len);

    // The next part to go is the time: at twelve bytes it still fits, at
    // eleven only the word does.
    const time_only = "working · 5m";
    var time_size: [time_only.len]u8 = undefined;
    try testing.expectEqualStrings(time_only, read(facts, &time_size).line);

    var eleven: [time_only.len - 1]u8 = undefined;
    const word = read(facts, &eleven);
    try testing.expectEqualStrings("working", word.line);
    try testing.expectEqual(Phase.working, word.phase);

    var six: [6]u8 = undefined;
    try testing.expectEqualStrings("", read(facts, &six).line);

    // A one-byte buffer still decides everything else; only the line gives way,
    // and the indicator never needed the buffer in the first place.
    var one: [1]u8 = undefined;
    const nothing = read(facts, &one);
    try testing.expectEqualStrings("", nothing.line);
    try testing.expectEqual(Phase.working, nothing.phase);
    try testing.expectEqualStrings("|", nothing.indicator);
    try testing.expectEqual(theme.amber, nothing.color);

    var zero: [0]u8 = undefined;
    try testing.expectEqualStrings("", read(facts, &zero).line);
}

test "the smallest buffer that fits anything holds the word, and one byte less holds nothing" {
    var word: [5]u8 = undefined;
    const ready = read(idle, &word);
    try testing.expectEqualStrings("ready", ready.line);
    try testing.expectEqual(@as(usize, 5), ready.line.len);

    var less: [4]u8 = undefined;
    const nothing = read(idle, &less);
    try testing.expectEqualStrings("", nothing.line);
    try testing.expectEqual(Phase.ready, nothing.phase);
    try testing.expectEqual(theme.accent, nothing.color);
}

test "a stalled lane keeps the silence even when nothing else fits" {
    const facts = Facts{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 90_000, .since_event_ms = 42_000, .subject = "run the test suite" };
    var full: [96]u8 = undefined;
    try testing.expectEqualStrings("stalled 1m in · run the test suite · no word for 42s", read(facts, &full).line);

    var no_subject: [40]u8 = undefined;
    try testing.expectEqualStrings("stalled 1m in · no word for 42s", read(facts, &no_subject).line);

    var no_age: [30]u8 = undefined;
    try testing.expectEqualStrings("stalled · no word for 42s", read(facts, &no_age).line);

    var word_only: [7]u8 = undefined;
    try testing.expectEqualStrings("stalled", read(facts, &word_only).line);
}

test "a busy lane with no times is starting, not stalled" {
    var buf: [64]u8 = undefined;
    const reading = read(.{ .state_label = "WORKING", .busy = true, .up = true }, &buf);
    try testing.expectEqual(Phase.starting, reading.phase);
    try testing.expectEqualStrings("starting", reading.line);
}

test "a multi-line subject or reason still reads as one line" {
    var buf: [64]u8 = undefined;
    const subject = read(.{ .state_label = "WORKING", .busy = true, .up = true, .since_start_ms = 6_000, .since_event_ms = 40, .subject = "  run the tests\nin the repo " }, &buf);
    try testing.expectEqualStrings("working · run the tests · 6s", subject.line);

    const reason = read(.{ .state_label = "OFFLINE", .busy = false, .up = false, .failure = "connection reset\r\nat 10:04" }, &buf);
    try testing.expectEqualStrings("failed · connection reset", reason.line);

    // A reason that is nothing but whitespace is no reason at all.
    const blank = read(.{ .state_label = "OFFLINE", .busy = false, .up = false, .failure = "\n \t" }, &buf);
    try testing.expectEqual(Phase.offline, blank.phase);
    try testing.expectEqualStrings("offline", blank.line);
}
