//! Asking a shell to report its own command boundaries.
//!
//! A terminal that guesses where a prompt ends is inventing evidence about what
//! a command did. The shells that can say so are asked to: the editor writes a
//! snippet and hands it to the shell it spawns, so the emulator sees real
//! OSC 133 markers rather than a screen somebody has to interpret.
//!
//! A shell that is not one of these is run exactly as it was.
const std = @import("std");
const c = @import("native");
const files = @import("../platform/files.zig");
const Allocator = std.mem.Allocator;

/// How to start a shell so that it marks its own commands.
pub const Plan = struct {
    /// Arguments for the shell, starting with the program itself. Mutable
    /// because it is built here and released by deinit.
    argv: [][]const u8,
    /// A variable the spawned process needs, if the shell reads its
    /// configuration from somewhere other than the home directory.
    variable: ?Variable = null,
    /// The snippet, which the process reads at startup and which the caller
    /// releases when the shell is gone.
    snippet: []u8,
    variable_name: []u8 = &.{},
    variable_value: []u8 = &.{},

    pub const Variable = struct { name: []const u8, value: []const u8 };

    pub fn deinit(self: *Plan, a: Allocator) void {
        // The words first: the array is what holds them, so releasing it before
        // reading it is reading freed memory.
        for (self.argv) |word| a.free(word);
        a.free(self.argv);
        if (self.variable_name.len > 0) a.free(self.variable_name);
        if (self.variable_value.len > 0) a.free(self.variable_value);
        a.free(self.snippet);
        self.* = undefined;
    }
};

const bash_snippet =
    \\# Seggs: mark where each command begins and ends, so the terminal reads
    \\# boundaries instead of guessing at them.
    \\[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
    \\__seggs_mark() { printf '\033]133;%s\007' "$1"; }
    \\PROMPT_COMMAND="__seggs_mark D; __seggs_mark A${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
    \\PS0='\033]133;B\007'
    \\
;

const zsh_snippet =
    \\# Seggs: mark where each command begins and ends, so the terminal reads
    \\# boundaries instead of guessing at them.
    \\# The editor points ZDOTDIR here so this file is the one zsh reads. That
    \\# variable is put back before the user's own configuration runs: it does
    \\# not know about this directory, and anything it caches there - zsh's
    \\# completion dump, for instance - would be written into a scratch folder
    \\# and fail.
    \\ZDOTDIR="$HOME"
    \\export ZDOTDIR
    \\[ -f "$HOME/.zshrc" ] && . "$HOME/.zshrc"
    \\__seggs_mark() { printf '\033]133;%s\007' "$1" }
    \\__seggs_precmd() { __seggs_mark D; __seggs_mark A }
    \\__seggs_preexec() { __seggs_mark B }
    \\typeset -ga precmd_functions preexec_functions
    \\precmd_functions+=(__seggs_precmd)
    \\preexec_functions+=(__seggs_preexec)
    \\
;

/// Prepare `shell_path` to report its commands. Null means this shell is not
/// one the integration knows, and it should be started as it always was.
pub fn integrate(a: Allocator, shell_path: []const u8) !?Plan {
    const name = std.fs.path.basename(shell_path);
    const is_bash = std.mem.startsWith(u8, name, "bash");
    const is_zsh = std.mem.startsWith(u8, name, "zsh");
    if (!is_bash and !is_zsh) return null;

    // bash is pointed at the file; zsh is pointed at a directory and reads
    // `.zshrc` out of it, so the two differ only in where it is written.
    const where = if (is_bash)
        try files.tempPath(a, "shell", ".bashrc")
    else blk: {
        const dir = try files.tempPath(a, "zdotdir", "");
        defer a.free(dir);
        const dir_z = try a.dupeSentinel(u8, dir, 0);
        defer a.free(dir_z);
        if (!c.SDL_CreateDirectory(dir_z.ptr)) return error.SnippetDirectory;
        break :blk try std.fmt.allocPrint(a, "{s}{c}.zshrc", .{ dir, std.fs.path.sep });
    };
    const where_z = try a.dupeSentinel(u8, where, 0);
    defer a.free(where_z);
    const source = if (is_bash) bash_snippet else zsh_snippet;
    const file = c.fopen(where_z.ptr, "wb") orelse return error.SnippetWrite;
    if (c.fwrite(source.ptr, 1, source.len, file) != source.len) {
        _ = c.fclose(file);
        return error.SnippetWrite;
    }
    if (c.fclose(file) != 0) return error.SnippetWrite;

    var plan: Plan = .{ .argv = &.{}, .snippet = where };
    errdefer plan.deinit(a);
    const count: usize = if (is_bash) 3 else 1;
    plan.argv = try a.alloc([]const u8, count);
    plan.argv[0] = try a.dupe(u8, shell_path);
    if (is_bash) {
        plan.argv[1] = try a.dupe(u8, "--rcfile");
        plan.argv[2] = try a.dupe(u8, where);
    } else {
        // The variable belongs to the process, not to the editor: a shell is
        // the only thing that reads it.
        plan.variable = .{ .name = "ZDOTDIR", .value = where };
        plan.variable_name = try a.dupe(u8, "ZDOTDIR");
        plan.variable_value = try a.dupe(u8, where);
    }
    return plan;
}

test "a shell the integration knows is given its markers, and another is not" {
    const a = std.testing.allocator;
    // A shell nobody integrated is left alone: the terminal runs it as before
    // and reads its screen as text.
    try std.testing.expect((try integrate(a, "/bin/fish")) == null);
    try std.testing.expect((try integrate(a, "/bin/sh")) == null);

    var bash = (try integrate(a, "/usr/bin/bash")) orelse return error.TestExpectedPlan;
    defer bash.deinit(a);
    try std.testing.expectEqualStrings("/usr/bin/bash", bash.argv[0]);
    try std.testing.expectEqualStrings("--rcfile", bash.argv[1]);
    try std.testing.expect(std.mem.endsWith(u8, bash.argv[2], ".bashrc"));

    // The snippet has to be on disk: the shell reads it, not us.
    const snippet = try files.read(a, bash.argv[2], 4096);
    defer a.free(snippet);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "]133;") != null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "bashrc") != null);

    var zsh = (try integrate(a, "/bin/zsh")) orelse return error.TestExpectedPlan;
    defer zsh.deinit(a);
    try std.testing.expectEqualStrings("/bin/zsh", zsh.argv[0]);
    try std.testing.expect(zsh.variable != null);
    try std.testing.expectEqualStrings("ZDOTDIR", zsh.variable.?.name);
}
