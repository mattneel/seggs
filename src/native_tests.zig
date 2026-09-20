const std = @import("std");
const builtin = @import("builtin");
const c = @import("native");
const files = @import("platform/files.zig");
const Workspace = @import("editor/workspace.zig").Workspace;
const review = @import("editor/review.zig");
const worktree = @import("services/worktree.zig");
const gitsvc = @import("services/git.zig");
const lsp = @import("services/lsp.zig");
const dap = @import("services/dap.zig");
const pty = @import("services/pty.zig");
const transport = @import("acp/transport.zig");
const shaper = @import("gpu/shaper.zig");
const yoga = @import("yoga");
const prompt = @import("editor/prompt.zig");
const ext_ui = @import("ext/ui.zig");

// Importing the module runs the tests it declares.
test {
    std.testing.refAllDecls(ext_ui);
}

const Allocator = std.mem.Allocator;

fn newDir(a: Allocator) ![]u8 {
    return std.fmt.allocPrint(a, "/tmp/seggs-save-{d}", .{c.SDL_GetPerformanceCounter()});
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
    var client = try lsp.Client.start(a, &.{ "python3", "tools/mock_lsp.py" }, ".");
    defer client.deinit();
    try client.open("test.txt", "hello");
    try std.testing.expectEqual(@as(usize, 1), client.diagnostics.items.len);
    try std.testing.expectEqualStrings("mock diagnostic", client.diagnostics.items[0].message);
    try std.testing.expectEqual(@as(u32, 1), client.diagnostics.items[0].line);
}

test "lsp client navigates to definitions and references" {
    const a = std.testing.allocator;
    var client = try lsp.Client.start(a, &.{ "python3", "tools/mock_lsp.py" }, ".");
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
    var client = try lsp.Client.start(a, &.{ "python3", "tools/mock_lsp.py" }, ".");
    defer client.deinit();
    // Raw newlines and quotes must stay valid JSON or the server cannot parse
    // the didOpen frame. This is the ordinary case for any real source file.
    try client.open("test.txt", "one\n\"two\"\nthree\n");
    try std.testing.expectEqual(@as(usize, 1), client.diagnostics.items.len);
}

test "dap client launches and observes the stopped event" {
    const a = std.testing.allocator;
    var client = try dap.Client.start(a, &.{ "python3", "tools/mock_dap.py" }, ".");
    defer client.deinit();
    try client.launch("test.zig", 1);
    try std.testing.expect(client.stopped);
}

test "dap client inspects and resumes a stopped session" {
    const a = std.testing.allocator;
    var client = try dap.Client.start(a, &.{ "python3", "tools/mock_dap.py" }, ".");
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
    var client = try lsp.Client.start(a, &.{ "python3", "tools/mock_lsp.py" }, ".");
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

test "pty spawns a shell and echoes output" {
    const a = std.testing.allocator;
    var p = try pty.Pty.spawn(a, &.{ "/bin/sh", "-c", "echo seggs-pty" });
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
