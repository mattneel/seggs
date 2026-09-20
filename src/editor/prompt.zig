const std = @import("std");
const Allocator = std.mem.Allocator;

/// One diagnostic worth showing the agent.
pub const Diagnostic = struct {
    /// Zero-based line in the attached file.
    line: u32,
    message: []const u8,
};

/// What travels with a prompt. Every field is optional, so a prompt can carry a
/// selection, diagnostics, both, or neither without special cases.
pub const Context = struct {
    /// File the selection and diagnostics came from.
    path: ?[]const u8 = null,
    /// Where in that file the selection sits, as a label like "12-40".
    range: ?[]const u8 = null,
    selection: ?[]const u8 = null,
    /// The file's own text, when the developer asked for the whole thing
    /// rather than a selection out of it.
    file: ?[]const u8 = null,
    diagnostics: []const Diagnostic = &.{},
    /// The command a terminal result came from, and how it ended. A result
    /// carries its own provenance, so the next step reads evidence rather than
    /// a summary of evidence.
    command: ?[]const u8 = null,
    exit: ?u8 = null,
    output: ?[]const u8 = null,
};

/// Build the outgoing prompt with the attached context ahead of the user's
/// text, so the agent sees exactly what the editor was showing. Owned result.
pub fn attach(a: Allocator, context: Context, prompt: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (context.selection) |selection| {
        if (selection.len > 0) {
            if (context.path) |path| {
                try out.appendSlice(a, "Selection in ");
                try out.appendSlice(a, path);
                if (context.range) |range| {
                    try out.appendSlice(a, ":");
                    try out.appendSlice(a, range);
                }
                try out.appendSlice(a, ":\n```\n");
            } else {
                try out.appendSlice(a, "Selected text:\n```\n");
            }
            try out.appendSlice(a, selection);
            try out.appendSlice(a, "\n```\n\n");
        }
    }
    if (context.file) |file| {
        if (file.len > 0) {
            try out.appendSlice(a, "File");
            if (context.path) |path| {
                try out.appendSlice(a, " ");
                try out.appendSlice(a, path);
            }
            try out.appendSlice(a, ":\n```\n");
            try out.appendSlice(a, file);
            try out.appendSlice(a, "\n```\n\n");
        }
    }
    if (context.output) |output| {
        if (output.len > 0) {
            try out.appendSlice(a, "Terminal output");
            if (context.command) |command| {
                try out.appendSlice(a, " from `");
                try out.appendSlice(a, command);
                try out.appendSlice(a, "`");
            }
            if (context.exit) |code| {
                var buffer: [24]u8 = undefined;
                const label = try std.fmt.bufPrint(&buffer, " (exit {d})", .{code});
                try out.appendSlice(a, label);
            }
            try out.appendSlice(a, ":\n```\n");
            try out.appendSlice(a, output);
            try out.appendSlice(a, "\n```\n\n");
        }
    }
    if (context.diagnostics.len > 0) {
        try out.appendSlice(a, "Diagnostics");
        if (context.path) |path| {
            try out.appendSlice(a, " in ");
            try out.appendSlice(a, path);
        }
        try out.appendSlice(a, ":\n");
        for (context.diagnostics) |diagnostic| {
            var buffer: [32]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&buffer, "line {d}: ", .{diagnostic.line + 1});
            try out.appendSlice(a, prefix);
            try out.appendSlice(a, diagnostic.message);
            try out.appendSlice(a, "\n");
        }
        try out.appendSlice(a, "\n");
    }
    try out.appendSlice(a, prompt);
    return out.toOwnedSlice(a);
}

test "attach carries selection, diagnostics, or neither" {
    const a = std.testing.allocator;
    const none = try attach(a, .{}, "explain");
    defer a.free(none);
    try std.testing.expectEqualStrings("explain", none);

    const selection_only = try attach(a, .{ .selection = "foo()" }, "explain");
    defer a.free(selection_only);
    try std.testing.expectEqualStrings("Selected text:\n```\nfoo()\n```\n\nexplain", selection_only);

    // An empty selection is the same as none.
    const empty_selection = try attach(a, .{ .selection = "" }, "explain");
    defer a.free(empty_selection);
    try std.testing.expectEqualStrings("explain", empty_selection);

    const diagnostics = [_]Diagnostic{
        .{ .line = 0, .message = "unused variable" },
        .{ .line = 11, .message = "expected ';'" },
    };
    const both = try attach(a, .{
        .path = "src/main.zig",
        .selection = "const x = 1;",
        .diagnostics = &diagnostics,
    }, "fix this");
    defer a.free(both);
    // A selection that knows where it came from says so, so the agent can ask
    // for more of the file rather than guessing.
    try std.testing.expectEqualStrings(
        "Selection in src/main.zig:\n```\nconst x = 1;\n```\n\n" ++
            "Diagnostics in src/main.zig:\n" ++
            "line 1: unused variable\n" ++
            "line 12: expected ';'\n\n" ++
            "fix this",
        both,
    );

    const ranged = try attach(a, .{
        .path = "src/app.zig",
        .range = "120-140",
        .selection = "fn draw() {}",
    }, "explain");
    defer a.free(ranged);
    try std.testing.expectEqualStrings(
        "Selection in src/app.zig:120-140:\n```\nfn draw() {}\n```\n\nexplain",
        ranged,
    );

    // A command result carries the command and how it ended: the exit status is
    // evidence, and a summary of it is not.
    const failed = try attach(a, .{
        .command = "zig build test",
        .exit = 1,
        .output = "3 errors",
    }, "fix this");
    defer a.free(failed);
    try std.testing.expectEqualStrings(
        "Terminal output from `zig build test` (exit 1):\n```\n3 errors\n```\n\nfix this",
        failed,
    );

    const whole = try attach(a, .{ .path = "src/app.zig", .file = "const x = 1;" }, "review");
    defer a.free(whole);
    try std.testing.expectEqualStrings("File src/app.zig:\n```\nconst x = 1;\n```\n\nreview", whole);

    // An empty result attaches nothing, the same as an empty selection.
    const silent = try attach(a, .{ .command = "true", .output = "" }, "next");
    defer a.free(silent);
    try std.testing.expectEqualStrings("next", silent);
}
