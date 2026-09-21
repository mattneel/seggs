const std = @import("std");
const math = @import("ui/math.zig");
const app = @import("app.zig");
const markdown = @import("ui/markdown.zig");
const builtin = @import("builtin");

/// The mock servers are Python programs. Windows installs the interpreter as
/// `python`, everything else as `python3`, and the build takes the same choice
/// for the mock it runs itself.
const python = if (builtin.os.tag == .windows) "python" else "python3";
const c = @import("native");
const files = @import("platform/files.zig");
const Workspace = @import("editor/workspace.zig").Workspace;
const review = @import("editor/review.zig");
const worktree = @import("services/worktree.zig");
const gitsvc = @import("services/git.zig");
const lsp = @import("services/lsp.zig");
const dap = @import("services/dap.zig");
const pty = @import("services/pty.zig");
const vt = @import("services/vt.zig");
const transport = @import("acp/transport.zig");
const shaper = @import("gpu/shaper.zig");
const yoga = @import("yoga");
const prompt = @import("editor/prompt.zig");
const ext_ui = @import("ext/ui.zig");

// Importing the module runs the tests it declares.
test {
    std.testing.refAllDecls(ext_ui);
    _ = process;
    _ = shell_integration;
    _ = terminals;
    _ = @import("acp/client.zig");
}

const process = @import("services/process.zig");
const shell_integration = @import("services/shell.zig");
const terminals = @import("services/terminals.zig");

const Allocator = std.mem.Allocator;

fn newDir(a: Allocator) ![]u8 {
    return files.tempPath(a, "save", "");
}

fn z(a: Allocator, path: []const u8) ![:0]u8 {
    return a.dupeSentinel(u8, path, 0);
}

fn git(a: Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const result = try worktree.run(a, cwd, argv);
    defer a.free(result.stdout);
    try std.testing.expectEqual(@as(c_int, 0), result.exit);
}

const Remover = struct {
    allocator: Allocator,
    fn callback(userdata: ?*anyopaque, directory: [*c]const u8, name: [*c]const u8) callconv(.c) c.SDL_EnumerationResult {
        const self: *Remover = @ptrCast(@alignCast(userdata.?));
        const dir = std.mem.span(directory);
        const base = std.mem.span(name);
        const joined = std.fs.path.join(self.allocator, &.{ dir, base }) catch return c.SDL_ENUM_FAILURE;
        defer self.allocator.free(joined);
        const path_z = self.allocator.dupeSentinel(u8, joined, 0) catch return c.SDL_ENUM_FAILURE;
        defer self.allocator.free(path_z);
        var info = std.mem.zeroes(c.SDL_PathInfo);
        if (!c.SDL_GetPathInfo(path_z.ptr, &info)) return c.SDL_ENUM_CONTINUE;
        if (info.type == c.SDL_PATHTYPE_DIRECTORY) {
            removeTree(self.allocator, joined);
            _ = c.SDL_RemovePath(path_z.ptr);
        } else {
            _ = c.SDL_RemovePath(path_z.ptr);
        }
        return c.SDL_ENUM_CONTINUE;
    }
};

fn removeTree(a: Allocator, path: []const u8) void {
    const path_z = a.dupeSentinel(u8, path, 0) catch return;
    defer a.free(path_z);
    var remover = Remover{ .allocator = a };
    _ = c.SDL_EnumerateDirectory(path_z.ptr, Remover.callback, &remover);
    _ = c.SDL_RemovePath(path_z.ptr);
}

test "save roundtrip writes through a temporary sibling" {
    const a = std.testing.allocator;
    const dir = try newDir(a);
    defer a.free(dir);
    const dirz = try z(a, dir);
    defer a.free(dirz);
    try std.testing.expect(c.SDL_CreateDirectory(dirz.ptr));
    defer _ = c.SDL_RemovePath(dirz.ptr);
    const file = try std.fmt.allocPrint(a, "{s}/file.txt", .{dir});
    defer a.free(file);
    const filez = try z(a, file);
    defer a.free(filez);
    defer _ = c.SDL_RemovePath(filez.ptr);
    try files.replace(a, file, "hello save gate");
    const bytes = try files.read(a, file, 1024 * 1024);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("hello save gate", bytes);
}

test "save into a missing directory reports SaveTemporary" {
    const a = std.testing.allocator;
    const dir = try newDir(a);
    defer a.free(dir);
    const dirz = try z(a, dir);
    defer a.free(dirz);
    try std.testing.expect(c.SDL_CreateDirectory(dirz.ptr));
    defer _ = c.SDL_RemovePath(dirz.ptr);
    const path = try std.fmt.allocPrint(a, "{s}/missing/file.txt", .{dir});
    defer a.free(path);
    try std.testing.expectError(error.SaveTemporary, files.replace(a, path, "x"));
}

test "save through a symlink replaces the target, not the link" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const dir = try newDir(a);
    defer a.free(dir);
    const dirz = try z(a, dir);
    defer a.free(dirz);
    try std.testing.expect(c.SDL_CreateDirectory(dirz.ptr));
    defer _ = c.SDL_RemovePath(dirz.ptr);
    const target = try std.fmt.allocPrint(a, "{s}/target.txt", .{dir});
    defer a.free(target);
    const targetz = try z(a, target);
    defer a.free(targetz);
    defer _ = c.SDL_RemovePath(targetz.ptr);
    const link = try std.fmt.allocPrint(a, "{s}/link.txt", .{dir});
    defer a.free(link);
    const linkz = try z(a, link);
    defer a.free(linkz);
    defer _ = c.SDL_RemovePath(linkz.ptr);
    try files.replace(a, target, "original");
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(targetz.ptr, linkz.ptr));

    // Saving through the link must update the file the link names. If the save
    // replaced the link instead, the target would still hold "original".
    try files.replace(a, link, "updated through the link");
    const bytes = try files.read(a, target, 1024 * 1024);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("updated through the link", bytes);
    const via_link = try files.read(a, link, 1024 * 1024);
    defer a.free(via_link);
    try std.testing.expectEqualStrings("updated through the link", via_link);
}

test "save into a read-only directory fails without touching the file" {
    // A read-only directory does not stop root, so this cannot hold as root.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (c.geteuid() == 0) return error.SkipZigTest;
    const a = std.testing.allocator;
    const dir = try newDir(a);
    defer a.free(dir);
    const dirz = try z(a, dir);
    defer a.free(dirz);
    try std.testing.expect(c.SDL_CreateDirectory(dirz.ptr));
    defer _ = c.SDL_RemovePath(dirz.ptr);
    const file = try std.fmt.allocPrint(a, "{s}/file.txt", .{dir});
    defer a.free(file);
    const filez = try z(a, file);
    defer a.free(filez);
    defer _ = c.SDL_RemovePath(filez.ptr);
    try files.replace(a, file, "original");

    // The temporary sibling cannot be created, so the save fails cleanly.
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(dirz.ptr, 0o500));
    const failure = files.replace(a, file, "replacement");
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(dirz.ptr, 0o700));
    try std.testing.expectError(error.SaveTemporary, failure);
    const bytes = try files.read(a, file, 1024 * 1024);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("original", bytes);
}

test "rename onto an existing directory reports FileRename" {
    const a = std.testing.allocator;
    const dir = try newDir(a);
    defer a.free(dir);
    const dirz = try z(a, dir);
    defer a.free(dirz);
    try std.testing.expect(c.SDL_CreateDirectory(dirz.ptr));
    defer _ = c.SDL_RemovePath(dirz.ptr);
    try std.testing.expectError(error.FileRename, files.replace(a, dir, "x"));
}

test "workspace opens and switches multiple documents" {
    const a = std.testing.allocator;
    const dir = try newDir(a);
    defer a.free(dir);
    const dirz = try z(a, dir);
    defer a.free(dirz);
    try std.testing.expect(c.SDL_CreateDirectory(dirz.ptr));
    defer _ = c.SDL_RemovePath(dirz.ptr);
    const file1 = try std.fmt.allocPrint(a, "{s}/one.txt", .{dir});
    defer a.free(file1);
    const file1z = try z(a, file1);
    defer a.free(file1z);
    defer _ = c.SDL_RemovePath(file1z.ptr);
    const file2 = try std.fmt.allocPrint(a, "{s}/two.txt", .{dir});
    defer a.free(file2);
    const file2z = try z(a, file2);
    defer a.free(file2z);
    defer _ = c.SDL_RemovePath(file2z.ptr);
    try files.replace(a, file1, "alpha");
    try files.replace(a, file2, "beta");

    var ws = try Workspace.init(a, dir);
    defer ws.deinit();
    try std.testing.expectEqual(@as(usize, 1), ws.bufferCount());
    try ws.open(file1);
    try ws.open(file2);
    try std.testing.expectEqual(@as(usize, 3), ws.bufferCount());
    {
        const beta = try ws.activeDocument().snapshot(a);
        defer a.free(beta);
        try std.testing.expectEqualStrings("beta", beta);
    }
    try ws.open(file1); // switch to an already-open buffer, not append
    try std.testing.expectEqual(@as(usize, 3), ws.bufferCount());
    try std.testing.expectEqual(@as(usize, 1), ws.activeIndex());
    {
        const alpha = try ws.activeDocument().snapshot(a);
        defer a.free(alpha);
        try std.testing.expectEqualStrings("alpha", alpha);
    }
    // Dirty state is per-buffer.
    try ws.activeDocument().insert("!");
    try std.testing.expect(ws.dirty());
    try ws.open(file2);
    try std.testing.expect(!ws.dirty());
}

test "workspace detects and reloads external edits" {
    const a = std.testing.allocator;
    const dir = try newDir(a);
    defer a.free(dir);
    const dirz = try z(a, dir);
    defer a.free(dirz);
    try std.testing.expect(c.SDL_CreateDirectory(dirz.ptr));
    defer _ = c.SDL_RemovePath(dirz.ptr);
    const file = try std.fmt.allocPrint(a, "{s}/watched.txt", .{dir});
    defer a.free(file);
    const filez = try z(a, file);
    defer a.free(filez);
    defer _ = c.SDL_RemovePath(filez.ptr);
    try files.replace(a, file, "one");

    var ws = try Workspace.init(a, dir);
    defer ws.deinit();
    try ws.open(file);
    try std.testing.expect(!ws.externalChanged(ws.activeIndex()));

    try files.replace(a, file, "changed");
    try std.testing.expect(ws.externalChanged(ws.activeIndex()));

    try ws.reload();
    {
        const bytes = try ws.activeDocument().snapshot(a);
        defer a.free(bytes);
        try std.testing.expectEqualStrings("changed", bytes);
    }
    try std.testing.expect(!ws.externalChanged(ws.activeIndex()));
}

test "workspace applies review edits by path" {
    const a = std.testing.allocator;
    const dir = try newDir(a);
    defer a.free(dir);
    const dirz = try z(a, dir);
    defer a.free(dirz);
    try std.testing.expect(c.SDL_CreateDirectory(dirz.ptr));
    defer _ = c.SDL_RemovePath(dirz.ptr);
    const file = try std.fmt.allocPrint(a, "{s}/review.txt", .{dir});
    defer a.free(file);
    const filez = try z(a, file);
    defer a.free(filez);
    defer _ = c.SDL_RemovePath(filez.ptr);
    try files.replace(a, file, "hello");

    var ws = try Workspace.init(a, dir);
    defer ws.deinit();
    try ws.open(file);
    var queue = review.ReviewQueue.init(a);
    defer queue.deinit();
    try queue.propose(.{ .path = file, .expected_revision = 0, .start_byte = 0, .end_byte = 5, .replacement = "hi" });
    try std.testing.expectEqual(review.Outcome.applied, try ws.applyReview(&queue, 0));
    {
        const bytes = try ws.activeDocument().snapshot(a);
        defer a.free(bytes);
        try std.testing.expectEqualStrings("hi", bytes);
    }
    try std.testing.expect(ws.dirty());
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}

test "worktree manager creates a worktree and detects conflicts" {
    const a = std.testing.allocator;
    const repo = try newDir(a);
    defer a.free(repo);
    const repoz = try z(a, repo);
    defer a.free(repoz);
    try std.testing.expect(c.SDL_CreateDirectory(repoz.ptr));
    defer removeTree(a, repo);
    try git(a, repo, &.{"init"});
    try git(a, repo, &.{ "config", "user.email", "t@t" });
    try git(a, repo, &.{ "config", "user.name", "t" });
    try git(a, repo, &.{ "config", "commit.gpgsign", "false" });
    // Line endings are the test's business, not the host's: a Windows checkout
    // rewrites the file it reads back, which is not what this test is about.
    try git(a, repo, &.{ "config", "core.autocrlf", "false" });
    const file = try std.fmt.allocPrint(a, "{s}/a.txt", .{repo});
    defer a.free(file);
    try files.replace(a, file, "one\n");
    try git(a, repo, &.{ "add", "." });
    try git(a, repo, &.{ "commit", "-m", "init" });
    try git(a, repo, &.{ "branch", "-m", "main" });

    const wt = try std.fmt.allocPrint(a, "{s}-wt", .{repo});
    defer a.free(wt);
    defer removeTree(a, wt);
    try worktree.createWorktree(a, repo, "feature", wt);

    const wt_file = try std.fmt.allocPrint(a, "{s}/a.txt", .{wt});
    defer a.free(wt_file);
    const wt_bytes = try files.read(a, wt_file, 1024 * 1024);
    defer a.free(wt_bytes);
    try std.testing.expectEqualStrings("one\n", wt_bytes);
    try std.testing.expect(!try worktree.hasConflicts(a, wt));

    // Diverge both sides, then merge to create a conflict.
    try files.replace(a, file, "main\n");
    try git(a, repo, &.{ "add", "." });
    try git(a, repo, &.{ "commit", "-m", "main" });
    try files.replace(a, wt_file, "feature\n");
    try git(a, wt, &.{ "add", "." });
    try git(a, wt, &.{ "commit", "-m", "feature" });
    const merge = try worktree.run(a, wt, &.{ "merge", "main" });
    a.free(merge.stdout);
    try std.testing.expect(try worktree.hasConflicts(a, wt));
}

test "git service reports status and diff" {
    const a = std.testing.allocator;
    const repo = try newDir(a);
    defer a.free(repo);
    const repoz = try z(a, repo);
    defer a.free(repoz);
    try std.testing.expect(c.SDL_CreateDirectory(repoz.ptr));
    defer removeTree(a, repo);
    try git(a, repo, &.{"init"});
    try git(a, repo, &.{ "config", "user.email", "t@t" });
    try git(a, repo, &.{ "config", "user.name", "t" });
    try git(a, repo, &.{ "config", "commit.gpgsign", "false" });
    // Line endings are the test's business, not the host's: a Windows checkout
    // rewrites the file it reads back, which is not what this test is about.
    try git(a, repo, &.{ "config", "core.autocrlf", "false" });
    const file = try std.fmt.allocPrint(a, "{s}/a.txt", .{repo});
    defer a.free(file);
    try files.replace(a, file, "one\n");
    try git(a, repo, &.{ "add", "." });
    try git(a, repo, &.{ "commit", "-m", "init" });
    // Modify the file: status and diff both become non-empty.
    try files.replace(a, file, "two\n");
    const status = try gitsvc.status(a, repo);
    defer a.free(status);
    try std.testing.expect(status.len > 0);
    const diff = try gitsvc.diff(a, repo);
    defer a.free(diff);
    try std.testing.expect(diff.len > 0);
}

test "lsp client collects diagnostics from the mock server" {
    const a = std.testing.allocator;
    // A mock that cannot start is the environment's problem, not the client's.
    var client = lsp.Client.start(a, &.{ python, "tools/mock_lsp.py" }, ".") catch return error.SkipZigTest;
    defer client.deinit();
    try client.open("test.txt", "hello");
    try std.testing.expectEqual(@as(usize, 1), client.diagnostics.items.len);
    try std.testing.expectEqualStrings("mock diagnostic", client.diagnostics.items[0].message);
    try std.testing.expectEqual(@as(u32, 1), client.diagnostics.items[0].line);
}

test "lsp client navigates to definitions and references" {
    const a = std.testing.allocator;
    // A mock that cannot start is the environment's problem, not the client's.
    var client = lsp.Client.start(a, &.{ python, "tools/mock_lsp.py" }, ".") catch return error.SkipZigTest;
    defer client.deinit();
    try client.open("test.txt", "hello");
    const target = (try client.definition("test.txt", 0, 0)) orelse return error.MissingDefinition;
    defer target.deinit(a);
    try std.testing.expectEqualStrings("test.txt", target.path);
    try std.testing.expectEqual(@as(u32, 0), target.line);
    const list = try client.references("test.txt", 0, 0);
    defer lsp.freeLocations(a, list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(u32, 2), list[1].line);
    try std.testing.expectEqual(@as(u32, 3), list[1].character);
    const text = (try client.hover("test.txt", 0, 0)) orelse return error.MissingHover;
    defer a.free(text);
    try std.testing.expectEqualStrings("mock hover", text);
}

test "lsp client escapes multiline document text" {
    const a = std.testing.allocator;
    // A mock that cannot start is the environment's problem, not the client's.
    var client = lsp.Client.start(a, &.{ python, "tools/mock_lsp.py" }, ".") catch return error.SkipZigTest;
    defer client.deinit();
    // Raw newlines and quotes must stay valid JSON or the server cannot parse
    // the didOpen frame. This is the ordinary case for any real source file.
    try client.open("test.txt", "one\n\"two\"\nthree\n");
    try std.testing.expectEqual(@as(usize, 1), client.diagnostics.items.len);
}

test "dap client launches and observes the stopped event" {
    const a = std.testing.allocator;
    var client = dap.Client.start(a, &.{ python, "tools/mock_dap.py" }, ".") catch return error.SkipZigTest;
    defer client.deinit();
    try client.launch("test.zig", 1);
    try std.testing.expect(client.stopped);
}

test "dap client inspects and resumes a stopped session" {
    const a = std.testing.allocator;
    var client = dap.Client.start(a, &.{ python, "tools/mock_dap.py" }, ".") catch return error.SkipZigTest;
    defer client.deinit();
    try client.launch("test.zig", 1);
    try std.testing.expect(client.stopped);
    const frames = try client.stackTrace();
    defer dap.freeFrames(a, frames);
    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("main", frames[0].name);
    try std.testing.expectEqual(@as(u32, 7), frames[0].line);
    const scope = (try client.firstScope()) orelse return error.MissingScope;
    const variables = try client.variables(scope);
    defer dap.freeVariables(a, variables);
    try std.testing.expectEqual(@as(usize, 2), variables.len);
    try std.testing.expectEqualStrings("count", variables[0].name);
    try std.testing.expectEqualStrings("3", variables[0].value);
    // Resuming drives the continued event and the next stop.
    try client.resumeThread("continue");
    try std.testing.expect(client.stopped);
    try client.resumeThread("next");
    try std.testing.expect(client.stopped);
}

test "transport queue enforces its item bound" {
    const a = std.testing.allocator;
    var queue = try transport.Queue.init(a);
    defer queue.deinit();
    var pushed: usize = 0;
    while (pushed < transport.Queue.max_items) : (pushed += 1) {
        const item = try a.dupe(u8, "{}");
        queue.push(item) catch |err| {
            a.free(item);
            return err;
        };
    }
    const extra = try a.dupe(u8, "{}");
    defer a.free(extra);
    try std.testing.expectError(error.QueueFull, queue.push(extra));
    // Draining one slot accepts the next item again.
    const drained = queue.pop() orelse return error.MissingItem;
    a.free(drained);
    const again = try a.dupe(u8, "{}");
    queue.push(again) catch |err| {
        a.free(again);
        return err;
    };
}

test "transport queue enforces its byte bound" {
    const a = std.testing.allocator;
    var queue = try transport.Queue.init(a);
    defer queue.deinit();
    const large = try a.alloc(u8, transport.Queue.max_bytes);
    queue.push(large) catch |err| {
        a.free(large);
        return err;
    };
    const extra = try a.dupe(u8, "{}");
    defer a.free(extra);
    try std.testing.expectError(error.QueueFull, queue.push(extra));
}

test "transport write tolerates short writes and a full pipe" {
    const a = std.testing.allocator;
    // Models a pipe that accepts a few bytes per call and then reports
    // not-ready until the reader drains it.
    const FillingSink = struct {
        received: std.ArrayList(u8) = .empty,
        per_call: usize,
        remaining_calls: usize,

        fn write(context: *anyopaque, bytes: []const u8) usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.remaining_calls == 0) return 0;
            self.remaining_calls -= 1;
            const take = @min(bytes.len, self.per_call);
            self.received.appendSlice(std.testing.allocator, bytes[0..take]) catch return 0;
            return take;
        }

        fn notReady(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.remaining_calls == 0;
        }
    };
    var state = FillingSink{ .per_call = 3, .remaining_calls = 2 };
    defer state.received.deinit(a);
    const sink = transport.Sink{ .context = &state, .write = FillingSink.write, .notReady = FillingSink.notReady };
    const packet = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n";
    var offset: usize = 0;
    var cycles: usize = 0;
    while (true) {
        if (try transport.writePacket(packet, &offset, sink)) break;
        cycles += 1;
        if (cycles > packet.len) return error.NoProgress;
        state.remaining_calls = 2; // the reader drained the pipe
    }
    // Several fill/drain cycles with three-byte writes still deliver the frame
    // exactly once, in order, with no duplication or loss.
    try std.testing.expect(cycles > 1);
    try std.testing.expectEqualStrings(packet, state.received.items);
}

test "transport write reports a stalled sink" {
    const Stalled = struct {
        fn write(_: *anyopaque, _: []const u8) usize {
            return 0;
        }
        fn notReady(_: *anyopaque) bool {
            return false;
        }
    };
    var context: u8 = 0;
    const sink = transport.Sink{ .context = &context, .write = Stalled.write, .notReady = Stalled.notReady };
    var offset: usize = 0;
    try std.testing.expectError(error.TransportWrite, transport.writePacket("{}", &offset, sink));
}

test "prompt attaches diagnostics a language server reported" {
    const a = std.testing.allocator;
    // A mock that cannot start is the environment's problem, not the client's.
    var client = lsp.Client.start(a, &.{ python, "tools/mock_lsp.py" }, ".") catch return error.SkipZigTest;
    defer client.deinit();
    try client.open("test.txt", "hello");
    const list = try a.alloc(prompt.Diagnostic, client.diagnostics.items.len);
    defer a.free(list);
    for (client.diagnostics.items, list) |source, *target| {
        target.* = .{ .line = source.line, .message = source.message };
    }
    const attached = try prompt.attach(a, .{ .path = "test.txt", .diagnostics = list }, "fix it");
    defer a.free(attached);
    try std.testing.expect(std.mem.indexOf(u8, attached, "Diagnostics in test.txt:") != null);
    try std.testing.expect(std.mem.indexOf(u8, attached, "mock diagnostic") != null);
    try std.testing.expect(std.mem.endsWith(u8, attached, "fix it"));
}

test "shaper maps codepoints to font glyph indices" {
    const a = std.testing.allocator;
    var s = shaper.Shaper.init(a, "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf") catch return error.SkipZigTest;
    defer s.deinit();
    // Latin, Latin-1, and Cyrillic are all in this face.
    try std.testing.expect(s.glyphIndex('A') != 0);
    try std.testing.expect(s.glyphIndex(0xE9) != 0);
    try std.testing.expect(s.glyphIndex(0x041F) != 0);
    // Distinct codepoints map to distinct glyphs, and unassigned ones to .notdef.
    try std.testing.expect(s.glyphIndex('A') != s.glyphIndex('B'));
    try std.testing.expectEqual(@as(u16, 0), s.glyphIndex(0x10FFFD));
}

test "shaper glyph indices select the same glyph as the codepoint" {
    const a = std.testing.allocator;
    if (!c.TTF_Init()) return error.FontSubsystem;
    var s = shaper.Shaper.init(a, "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf") catch return error.SkipZigTest;
    defer s.deinit();
    const font = c.TTF_OpenFont("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 32) orelse return error.FontOpen;
    defer c.TTF_CloseFont(font);
    var mismatches: usize = 0;
    for (33..127) |cp| {
        const by_codepoint = c.TTF_GetGlyphImage(font, @intCast(cp), null) orelse continue;
        defer c.SDL_DestroySurface(by_codepoint);
        const glyph_index: c_uint = s.glyphIndex(@intCast(cp));
        const by_index = c.TTF_GetGlyphImageForIndex(font, glyph_index, null) orelse {
            mismatches += 1;
            continue;
        };
        defer c.SDL_DestroySurface(by_index);
        if (by_codepoint.*.w != by_index.*.w or by_codepoint.*.h != by_index.*.h) {
            mismatches += 1;
            if (mismatches <= 5) std.debug.print("{c}: cp {d}x{d} vs index {d}x{d}\n", .{ @as(u8, @intCast(cp)), by_codepoint.*.w, by_codepoint.*.h, by_index.*.w, by_index.*.h });
        }
    }
    std.debug.print("PROBE mismatched glyphs: {d}\n", .{mismatches});
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "yoga lays out a row with one flexible child" {
    const row = yoga.YGNodeNew() orelse return error.NoNode;
    defer yoga.YGNodeFree(row);
    yoga.YGNodeStyleSetWidth(row, 300);
    yoga.YGNodeStyleSetHeight(row, 100);
    yoga.YGNodeStyleSetFlexDirection(row, yoga.YGFlexDirectionRow);

    const fixed = yoga.YGNodeNew() orelse return error.NoNode;
    defer yoga.YGNodeFree(fixed);
    yoga.YGNodeStyleSetWidth(fixed, 40);
    _ = yoga.YGNodeInsertChild(row, fixed, 0);

    const flexible = yoga.YGNodeNew() orelse return error.NoNode;
    defer yoga.YGNodeFree(flexible);
    yoga.YGNodeStyleSetFlexGrow(flexible, 1);
    _ = yoga.YGNodeInsertChild(row, flexible, 1);

    yoga.YGNodeCalculateLayout(row, std.math.nan(f32), std.math.nan(f32), yoga.YGDirectionLTR);
    try std.testing.expectEqual(@as(f32, 40), yoga.YGNodeLayoutGetWidth(fixed));
    try std.testing.expectEqual(@as(f32, 260), yoga.YGNodeLayoutGetWidth(flexible));
    try std.testing.expectEqual(@as(f32, 40), yoga.YGNodeLayoutGetLeft(flexible));
    try std.testing.expectEqual(@as(f32, 100), yoga.YGNodeLayoutGetHeight(flexible));
}

test "yoga measures a leaf through a callback and nests a column inside it" {
    const Text = struct {
        fn measure(_: yoga.YGNodeConstRef, width: f32, width_mode: yoga.YGMeasureMode, height: f32, height_mode: yoga.YGMeasureMode) callconv(.c) yoga.YGSize {
            _ = .{ width, width_mode, height, height_mode };
            // Two lines of sixteen pixels, which is what a text leaf reports.
            return .{ .width = 96, .height = 32 };
        }
    };
    const column = yoga.YGNodeNew() orelse return error.NoNode;
    defer yoga.YGNodeFree(column);
    yoga.YGNodeStyleSetPadding(column, yoga.YGEdgeAll, 8);
    yoga.YGNodeStyleSetFlexDirection(column, yoga.YGFlexDirectionColumn);

    const title = yoga.YGNodeNew() orelse return error.NoNode;
    defer yoga.YGNodeFree(title);
    yoga.YGNodeSetMeasureFunc(title, Text.measure);
    _ = yoga.YGNodeInsertChild(column, title, 0);

    const body = yoga.YGNodeNew() orelse return error.NoNode;
    defer yoga.YGNodeFree(body);
    yoga.YGNodeSetMeasureFunc(body, Text.measure);
    _ = yoga.YGNodeInsertChild(column, body, 1);

    yoga.YGNodeCalculateLayout(column, std.math.nan(f32), std.math.nan(f32), yoga.YGDirectionLTR);
    // The column wraps its measured children plus its own padding.
    try std.testing.expectEqual(@as(f32, 112), yoga.YGNodeLayoutGetWidth(column));
    try std.testing.expectEqual(@as(f32, 80), yoga.YGNodeLayoutGetHeight(column));
    try std.testing.expectEqual(@as(f32, 8), yoga.YGNodeLayoutGetTop(title));
    try std.testing.expectEqual(@as(f32, 40), yoga.YGNodeLayoutGetTop(body));
}

const quickjs = @import("quickjs");

test "the terminal service's own tests are collected" {
    // Declarations are analysed lazily, so a file's tests only exist once
    // something in the test root refers to it.
    _ = vt.Terminal;
}
const ext = @import("ext/host.zig");

test "the host loads a bundle whose source comes from a file" {
    // A bundle that arrived through the file system used to misparse here: the
    // engine's lexer reads past the last byte of the source it is given, so the
    // meaning depended on what the allocator had left behind the read buffer.
    const a = std.testing.allocator;
    const dir = try newDir(a);
    defer a.free(dir);
    const dirz = try z(a, dir);
    defer a.free(dirz);
    try std.testing.expect(c.SDL_CreateDirectory(dirz.ptr));
    defer _ = removeTree(a, dir);
    const bundle = try std.fs.path.join(a, &.{ dir, "bundle.js" });
    defer a.free(bundle);
    try files.replace(a, bundle, "(function () { seggs.status(\"plain\"); })();\n(() => { seggs.status(\"arrow\"); })();\n");
    var host = ext.Host.init(a);
    defer host.deinit();
    try std.testing.expectEqual(@as(usize, 1), host.loadExtensions(dir));
    try std.testing.expect(host.firstProblem() == null);
    // The bundle ran, not merely parsed: the second call is what the host holds.
    try std.testing.expectEqualStrings("arrow", host.status());
}

test "a terminal read returns nothing rather than blocking when idle" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var shell = try pty.Pty.spawn(a, &.{ "/bin/sh", "-c", "sleep 5" }, 80, 24);
    defer shell.deinit();
    try shell.setNonBlocking();
    var buffer: [256]u8 = undefined;
    const started = c.SDL_GetTicks();
    // Reading twice must return at once: the shell has said nothing yet, and
    // the editor cannot afford to wait for it mid-frame.
    for (0..2) |_| {
        const count = try shell.readOutput(&buffer);
        try std.testing.expectEqual(@as(usize, 0), count);
    }
    try std.testing.expect(c.SDL_GetTicks() - started < 1000);
}

test "the explorer omits directories the project generates" {
    const a = std.testing.allocator;
    const dir = try newDir(a);
    defer a.free(dir);
    const dirz = try z(a, dir);
    defer a.free(dirz);
    try std.testing.expect(c.SDL_CreateDirectory(dirz.ptr));
    defer _ = removeTree(a, dir);
    // One source file, and the directories the editor and the build create.
    for ([_][]const u8{ "keep.md", ".seggs", "zig-out", "book" }) |name| {
        const path = try std.fs.path.join(a, &.{ dir, name });
        defer a.free(path);
        const pathz = try z(a, path);
        defer a.free(pathz);
        if (std.mem.endsWith(u8, name, ".md")) {
            try files.replace(a, path, "text");
        } else {
            try std.testing.expect(c.SDL_CreateDirectory(pathz.ptr));
        }
    }
    var explorer = try files.Explorer.init(a, dir);
    defer explorer.deinit();
    for (explorer.entries.items) |entry| {
        const relative = entry[dir.len + 1 ..];
        try std.testing.expect(!std.mem.eql(u8, relative, ".seggs"));
        try std.testing.expect(!std.mem.eql(u8, relative, "zig-out"));
        try std.testing.expect(!std.mem.eql(u8, relative, "book"));
    }
    var saw_source = false;
    for (explorer.entries.items) |entry| {
        if (std.mem.eql(u8, entry[dir.len + 1 ..], "keep.md")) saw_source = true;
    }
    try std.testing.expect(saw_source);
}

test "a shell is told how big its terminal is, and told again when it changes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var p = try pty.Pty.spawn(a, &.{"/bin/sh"}, 80, 24);
    defer p.deinit();
    // The shell asks the kernel, which is the only thing that knows: this is
    // the size the program lays its prompt and its output out for. A terminal
    // that never says is a terminal of no width, and the program draws
    // nothing.
    try p.writeInput("stty size\n");
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len and std.mem.indexOf(u8, buf[0..n], "24 80") == null) {
        const count = p.readOutput(buf[n..]) catch break;
        if (count == 0) break;
        n += count;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "24 80") != null);

    // Resizing the dock has to reach the shell the same way, or the program
    // keeps drawing for the terminal it was born with.
    p.resize(120, 40);
    try p.writeInput("stty size\n");
    n = 0;
    while (n < buf.len and std.mem.indexOf(u8, buf[0..n], "40 120") == null) {
        const count = p.readOutput(buf[n..]) catch break;
        if (count == 0) break;
        n += count;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "40 120") != null);
}

test "a shell's first prompt arrives without any input being sent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var p = try pty.Pty.spawn(a, &.{"/bin/sh"}, 80, 24);
    defer p.deinit();
    // The editor polls rather than blocks, so the read that finds nothing yet
    // has to leave the output for the next one. A shell that only speaks when
    // spoken to would show an empty terminal until the first keystroke, which
    // is what a reader sees as a terminal that never opened.
    try p.setNonBlocking();
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    var tries: usize = 0;
    // The editor comes back to this every frame; the loop here just stands in
    // for enough frames that a shell which is going to speak has spoken.
    while (n == 0 and tries < 200_000) : (tries += 1) {
        const count = p.readOutput(buf[n..]) catch break;
        n += count;
    }
    try std.testing.expect(n > 0);
}

test "a palette set on a terminal is the palette it reports" {
    const a = std.testing.allocator;
    var t = try vt.Terminal.init(a, 80, 24);
    defer t.deinit();
    const before = try t.colors();

    // The colours a theme carries: a background and an ANSI pair, which is all
    // an editor theme ever names. The other 240 entries belong to the emulator
    // and must be left where they were.
    var ansi: @TypeOf(@as(vt.Terminal.Palette, undefined).ansi) = undefined;
    for (&ansi, 0..) |*entry, index| entry.* = .{ .r = @intCast(index * 15), .g = 0, .b = 0 };
    const palette = vt.Terminal.Palette{
        .foreground = .{ .r = 0xdc, .g = 0xe2, .b = 0xed },
        .background = .{ .r = 0x10, .g = 0x12, .b = 0x16 },
        .cursor = .{ .r = 0xff, .g = 0x00, .b = 0x00 },
        .ansi = ansi,
    };
    try t.setPalette(palette);
    // The colours are reported from the render state, which is taken when the
    // terminal is updated: a set with no update behind it is not yet a state
    // anything can read.
    try t.update();

    const after = try t.colors();
    // The render state reports a value near the one set rather than the exact
    // byte: the emulator owns its own colour handling on the way to the screen.
    // So this asserts that the theme reached it and kept its shape - the ramp
    // still rises, and the background is still the dark the theme asked for -
    // rather than pinning a byte the emulator is free to adjust.
    const close = struct {
        fn to(value: u8, wanted: u8) bool {
            return if (value > wanted) value - wanted <= 8 else wanted - value <= 8;
        }
    }.to;
    try std.testing.expect(close(after.background.r, 0x10));
    try std.testing.expect(after.palette[2].r > after.palette[1].r);
    try std.testing.expect(close(after.palette[1].r, 15));

    // Beyond the sixteen the theme is silent, so those are the emulator's own.
    try std.testing.expectEqual(before.palette[200].r, after.palette[200].r);
    try std.testing.expectEqual(before.palette[200].g, after.palette[200].g);
}

test "a shell that exits is reported as ended" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var p = try pty.Pty.spawn(a, &.{ "/bin/sh", "-c", "exit 7" }, 80, 24);
    defer p.deinit();
    try p.setNonBlocking();
    try std.testing.expect(!p.ended());
    var buf: [256]u8 = undefined;
    var tries: usize = 0;
    while (!p.ended() and tries < 200_000) : (tries += 1) {
        _ = p.readOutput(&buf) catch break;
    }
    // The program said nothing and left. The terminal has to say so, or the
    // editor keeps a tab whose program is gone and can never answer again.
    try std.testing.expect(p.ended());
}

test "pty spawns a shell and echoes output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var p = try pty.Pty.spawn(a, &.{ "/bin/sh", "-c", "echo seggs-pty" }, 80, 24);
    defer p.deinit();
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len and std.mem.indexOf(u8, buf[0..n], "seggs-pty") == null) {
        const count = p.readOutput(buf[n..]) catch break;
        if (count == 0) break;
        n += count;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "seggs-pty") != null);
}

test "the TeX engine lays out a formula" {
    // The engine reads its tables from a directory, so this is the one test that
    // needs the dependency tree present. It is fetched by the bootstrap, not
    // committed, so a tree without it skips rather than fails - the same
    // bargain the live-agent integration tests make.
    if (!math.init(math.resourceDir())) return error.SkipZigTest;

    // "\frac{1}{3}", as codepoints: the engine reads mathematics as text, not
    // as bytes.
    var source: [11]u32 = undefined;
    const text = "\\frac{1}{3}";
    for (text, 0..) |byte, i| source[i] = byte;

    const formula = math.parse(&source, 0, 20, 0, .{ 1, 1, 1, 1 }) orelse return error.ParseFailed;
    defer formula.deinit();

    const metrics = formula.measure();
    // A fraction stacks a numerator over a denominator, so it is narrower than
    // it is tall - which a formula renderer that ignored the layout would get
    // wrong by drawing the source.
    try std.testing.expect(metrics.width > 0);
    try std.testing.expect(metrics.height > metrics.width);
    // The denominator hangs below the baseline, and the engine reports that
    // separately because placing the formula in a row of text needs it.
    try std.testing.expect(metrics.depth > 0);
}

test "a cached formula holds after the frame that laid it out is gone" {
    // The transcript lays its rows out against a frame arena that is reset when
    // the frame ends, and a formula is cached for the life of the process. A
    // cache built out of that arena would hold pointers into memory that the
    // next frame has already reused, which is a segfault rather than a wrong
    // answer - so the sequence below is the one that has to be safe.
    if (!math.init(math.resourceDir())) return error.SkipZigTest;

    var source: [11]u32 = undefined;
    const text = "\\frac{1}{3}";
    for (text, 0..) |byte, i| source[i] = byte;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Churn the arena the way a frame does, so anything held on it is reused
    // rather than merely released.
    _ = try arena.allocator().alloc(u8, 4096);
    _ = arena.reset(.retain_capacity);

    const first = math.parseCached(&source, 20, 0, .{ 1, 1, 1, 1 }) orelse return error.ParseFailed;

    // A whole frame passes, and the arena it ran on is reset.
    _ = try arena.allocator().alloc(u8, 4096);
    _ = arena.reset(.retain_capacity);

    // The second call is answered from the cache, and it is the same layout:
    // laying it out again would be a different handle.
    const second = math.parseCached(&source, 20, 0, .{ 1, 1, 1, 1 }) orelse return error.ParseFailed;
    try std.testing.expectEqual(first.handle, second.handle);
    try std.testing.expect(second.measure().width > 0);
}

test "the transcript typesets a display formula instead of showing its source" {
    // The contract is the rows, not the engine: the engine laid formulas out
    // correctly while the transcript went on drawing the LaTeX, because the form
    // an agent writes was not the form the parser opened a display block with.
    // So this asserts what the reader sees.
    // The transcript lays its rows out against an arena that it throws away
    // whole, so the test does the same rather than tracking every span.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Asserted, not skipped. The tree is present in every build that gets this
    // far, and a skip is how that went unnoticed.
    try std.testing.expect(math.init(math.resourceDir()));

    // Both ways an agent writes display math, because they reach the parser by
    // different roads - delimiters on one line, and an opener and closer of
    // their own.
    const sources = [_][]const u8{
        "A fraction:\n\n$$\\frac{1}{3}$$\n\nAnd after.\n",
        "A fraction:\n\n$$\n\\frac{1}{3}\n$$\n\nAnd after.\n",
    };
    for (sources) |source| {
        const blocks = try markdown.parse(a, source);
        const rows = try app.transcriptRows(a, blocks, 80, 9.5, 22);

        var typeset: ?app.RowFormula = null;
        var at: usize = 0;
        for (rows, 0..) |row, i| {
            if (row.formula) |formula| {
                typeset = formula;
                at = i;
            }
        }
        // A row carries the layout, and a fraction is taller than it is wide -
        // which a row of source text is not.
        try std.testing.expect(typeset != null);
        try std.testing.expect(typeset.?.height > typeset.?.width);
        // A fraction is taller than one line, so it must occupy more than one
        // row: the walk gives each row a single line of height, and a formula
        // that claimed only one was drawn over the block under it.
        try std.testing.expect(rows[at].lines > 1);
        for (rows[at + 1 .. at + rows[at].lines]) |row| {
            try std.testing.expect(row.continuation);
        }
        // And the source is replaced rather than drawn beside the formula, which
        // is what "jumbled" was: both of them at once.
        for (rows) |row| {
            for (row.spans) |span| {
                try std.testing.expect(std.mem.indexOf(u8, span.text, "\\frac") == null);
            }
        }
    }
}
