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
    selection: ?[]const u8 = null,
    diagnostics: []const Diagnostic = &.{},
};

/// Build the outgoing prompt with the attached context ahead of the user's
/// text, so the agent sees exactly what the editor was showing. Owned result.
pub fn attach(a: Allocator, context: Context, prompt: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (context.selection) |selection| {
        if (selection.len > 0) {
            try out.appendSlice(a, "Selected text:\n```\n");
            try out.appendSlice(a, selection);
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
    try std.testing.expectEqualStrings(
        "Selected text:\n```\nconst x = 1;\n```\n\n" ++
            "Diagnostics in src/main.zig:\n" ++
            "line 1: unused variable\n" ++
            "line 12: expected ';'\n\n" ++
            "fix this",
        both,
    );
}
