//! What a session says about itself, as the interface draws it: its name, and
//! the mode it is in.
//!
//! These are not transcript lines. A title belongs to the transcript's own
//! header - it names the thing a reader is looking at rather than something that
//! happened in it - and the mode is a setting the agent is working under, which
//! a reader wants to be able to check without scrolling back to where it
//! changed. Neither is placed by an offset, because neither happened at one.
//!
//! Both answer `null` when the session has not said: a header showing an empty
//! session name, or a mode row with no mode in it, is a line about nothing, and
//! the caller that draws one has nothing to draw.

const std = @import("std");
const tool_card = @import("tool_card.zig");
const Allocator = std.mem.Allocator;

/// The transcript's header: what this session is called, and when it last moved.
///
/// One line, because a header is a place rather than a paragraph. The activity
/// stamp is the agent's own ISO 8601 timestamp, printed as it arrived: reading
/// it, formatting it into a locale, or calling it "2 hours ago" would need a
/// clock this module does not have and would make the header disagree with the
/// agent about when things happened.
pub fn titleCard(title: []const u8, activity: []const u8, a: Allocator) !?tool_card.Card {
    if (title.len == 0) return null;
    return .{
        .status = "session",
        .subject = if (activity.len == 0)
            title
        else
            try std.fmt.allocPrint(a, "{s} · updated {s}", .{ title, activity }),
        .tone = .plain,
        .variant = .plain,
    };
}

/// The mode a session is in, as one line for beside the transcript.
///
/// Only the mode's id is on the wire (`current_mode_update` carries
/// `currentModeId`): the name for it is not in the update, so this draws the id
/// the agent used rather than inventing a friendlier one.
pub fn modeCard(mode: []const u8) ?tool_card.Card {
    if (mode.len == 0) return null;
    return .{
        .status = "mode",
        .subject = mode,
        // A setting is chrome rather than content: a reader looks at it on
        // purpose rather than reading past it.
        .tone = .muted,
        .variant = .plain,
    };
}

test "a title names the session and says when it last moved" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();

    const named = (try titleCard("Overhaul the transcript", "2026-09-21T10:00:00Z", frame)).?;
    try std.testing.expectEqualStrings("session", named.status);
    try std.testing.expectEqualStrings("Overhaul the transcript · updated 2026-09-21T10:00:00Z", named.subject);
    try std.testing.expectEqual(tool_card.Variant.plain, named.variant);

    // A title with no activity is the title rather than a dangling separator.
    const quiet = (try titleCard("Overhaul the transcript", "", frame)).?;
    try std.testing.expectEqualStrings("Overhaul the transcript", quiet.subject);

    // A session that has not said what it is called has no header to draw.
    try std.testing.expectEqual(@as(?tool_card.Card, null), try titleCard("", "2026-09-21T10:00:00Z", frame));
}

test "a mode row draws the id the agent used, and nothing when there is none" {
    const mode = modeCard("plan").?;
    try std.testing.expectEqualStrings("mode", mode.status);
    try std.testing.expectEqualStrings("plan", mode.subject);
    try std.testing.expectEqual(tool_card.Tone.muted, mode.tone);
    try std.testing.expectEqual(@as(?tool_card.Card, null), modeCard(""));
}
