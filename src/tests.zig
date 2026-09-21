test {
    _ = @import("core/text.zig");
    _ = @import("core/preedit.zig");
    _ = @import("gpu/packer.zig");
    _ = @import("editor/gap_buffer.zig");
    _ = @import("editor/document.zig");
    _ = @import("editor/highlight.zig");
    // The two importers are read by nothing until something asks for them, so
    // naming them here is what puts their tests in the suite.
    _ = @import("services/theme_tm.zig");
    _ = @import("services/theme_vscode.zig");
    // The transcript's two parsers: a Markdown block list and a unified diff,
    // read by the drawing path rather than by each other.
    _ = @import("ui/markdown.zig");
    _ = @import("ui/diff.zig");
    // What a lane says about itself: the line a reader glances at, and the
    // difference between working and stuck.
    _ = @import("ui/activity.zig");
    _ = @import("editor/review.zig");
    _ = @import("editor/prompt.zig");
    _ = @import("editor/runs.zig");
    _ = @import("acp/framing.zig");
    _ = @import("acp/protocol.zig");
    // A tool call as a record with an offset into the transcript, so a chip
    // lands where the call happened rather than at the end.
    _ = @import("acp/tool_call.zig");
    _ = @import("agents/registry.zig");
    _ = @import("ui/layout.zig");
    _ = @import("ui/wrap.zig");
    _ = @import("ui/tree.zig");
    _ = @import("ui/menu.zig");
}
