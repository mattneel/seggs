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
    // The catalog of themes on disk, and the two importers it reads them
    // through: named here for the same reason they are.
    _ = @import("ui/theme_catalog.zig");
    // The theme switcher's own state, over that catalog's rows.
    _ = @import("ui/theme_picker.zig");
    // The registry that decides which shape draws a call. Its cards are data,
    // so it is named here rather than in a target that needs a display.
    _ = @import("ui/tools/index.zig");
    // What the agent streams: reasoning, the user's own words, and the
    // summaries a compaction leaves behind.
    _ = @import("acp/stream.zig");
    // The one content part that is not words: a picture, kept as the image file
    // it carried, the decode that turns those bytes into pixels under limits of
    // its own, and the line and the box the transcript draws it as.
    _ = @import("acp/image.zig");
    _ = @import("gpu/image.zig");
    _ = @import("ui/image_card.zig");
    // The state an agent announces rather than says: its plan, its context
    // budget, its mode, and the commands it takes.
    _ = @import("acp/plan.zig");
    _ = @import("acp/session_state.zig");
    _ = @import("acp/limits.zig");
    // What those records look like drawn: a plan as a checklist, the context
    // and cost as a row of figures, a run of reasoning as a fold.
    _ = @import("ui/plan_card.zig");
    _ = @import("ui/usage_card.zig");
    _ = @import("ui/stream_card.zig");
    _ = @import("ui/session_cards.zig");
    _ = @import("ui/palette.zig");
    _ = @import("ui/folds.zig");
}
