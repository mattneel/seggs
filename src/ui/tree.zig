//! A directory tree derived from a flat list of paths.
//!
//! The workspace enumerates files; a navigator shows folders. This turns one
//! into the other without touching the filesystem: paths in, rows out, with the
//! folders the reader has opened. It is a model rather than a drawing, so the
//! collapsing can be tested without a window.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Node = struct {
    /// Full path as given, owned by the tree.
    path: []u8,
    /// The last segment, borrowed from `path`.
    name: []const u8,
    parent: ?usize,
    depth: usize,
    folder: bool,
    /// Positions of this node's children in the tree's list, in draw order.
    children: std.ArrayListUnmanaged(usize) = .empty,
};

pub const Tree = struct {
    allocator: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    /// Children of the root, in draw order.
    roots: std.ArrayListUnmanaged(usize) = .empty,
    /// Folders the reader has opened, by path.
    expanded: std.StringHashMapUnmanaged(void) = .{},

    pub fn init(a: Allocator) Tree {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Tree) void {
        for (self.nodes.items) |*node| {
            self.allocator.free(node.path);
            node.children.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        var keys = self.expanded.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.expanded.deinit(self.allocator);
    }

    pub fn isExpanded(self: *const Tree, path: []const u8) bool {
        return self.expanded.contains(path);
    }

    /// Open a folder, or close it. Whether it has children is not this function's
    /// business: a folder with nothing in it is a folder that draws nothing.
    pub fn toggle(self: *Tree, path: []const u8) !void {
        if (self.expanded.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            return;
        }
        try self.expand(path);
    }

    pub fn expand(self: *Tree, path: []const u8) !void {
        if (self.expanded.contains(path)) return;
        try self.expanded.put(self.allocator, try self.allocator.dupe(u8, path), {});
    }

    /// Build the tree from paths, which may be files or folders and are expected
    /// to be relative to a root nobody here needs to know.
    ///
    /// Folders come before files among siblings and each group is alphabetical,
    /// because a navigator that reorders itself as files appear is one nobody
    /// can learn.
    pub fn rebuild(self: *Tree, paths: []const []const u8) !void {
        for (self.nodes.items) |*node| {
            self.allocator.free(node.path);
            node.children.deinit(self.allocator);
        }
        self.nodes.clearRetainingCapacity();
        self.roots.clearRetainingCapacity();

        for (paths) |path| try self.insert(path);
        try self.order();
    }

    fn insert(self: *Tree, path: []const u8) !void {
        var parent: ?usize = null;
        var depth: usize = 0;
        var index: usize = 0;
        while (index <= path.len) : (index += 1) {
            if (index == 0) continue;
            if (index < path.len and path[index] != '/') continue;
            const segment = path[0..index];
            const folder = index < path.len;
            parent = if (self.find(segment)) |found|
                found
            else blk: {
                const owned = try self.allocator.dupe(u8, segment);
                errdefer self.allocator.free(owned);
                try self.nodes.append(self.allocator, .{
                    .path = owned,
                    .name = std.fs.path.basename(owned),
                    .parent = parent,
                    .depth = depth,
                    .folder = folder,
                });
                break :blk self.nodes.items.len - 1;
            };
            depth += 1;
        }
    }

    /// A node is the same node when it has the same path, which is what keeps a
    /// folder shared by two files from appearing twice.
    fn find(self: *Tree, path: []const u8) ?usize {
        for (self.nodes.items, 0..) |node, index| {
            if (std.mem.eql(u8, node.path, path)) return index;
        }
        return null;
    }

    /// Put every node under its parent and sort each group: folders first, then
    /// names. The tree is rebuilt after a change rather than patched, so a
    /// half-sorted list is not a state anything can observe.
    fn order(self: *Tree) !void {
        for (self.nodes.items, 0..) |*node, index| {
            if (node.parent) |parent| {
                try self.nodes.items[parent].children.append(self.allocator, index);
            } else {
                try self.roots.append(self.allocator, index);
            }
        }
        for (self.nodes.items) |*node| sortIndices(self.nodes.items, node.children.items);
        sortIndices(self.nodes.items, self.roots.items);
    }

    fn sortIndices(nodes: []Node, indices: []usize) void {
        const Context = struct {
            nodes: []Node,
            fn lessThan(context: @This(), left: usize, right: usize) bool {
                const a = context.nodes[left];
                const b = context.nodes[right];
                if (a.folder != b.folder) return a.folder;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        };
        std.mem.sort(usize, indices, Context{ .nodes = nodes }, Context.lessThan);
    }

    /// Visit the rows to draw, in order: a node, then its children when it is an
    /// open folder.
    pub fn visit(self: *const Tree, context: anytype, comptime visitNode: fn (@TypeOf(context), *const Node) anyerror!void) !void {
        for (self.roots.items) |root| try self.walk(root, context, visitNode);
    }

    fn walk(self: *const Tree, index: usize, context: anytype, comptime visitNode: fn (@TypeOf(context), *const Node) anyerror!void) !void {
        const node = &self.nodes.items[index];
        try visitNode(context, node);
        if (!node.folder or !self.expanded.contains(node.path)) return;
        for (node.children.items) |child| try self.walk(child, context, visitNode);
    }

    /// The row at a position in the drawn order, for turning a click into a
    /// node. Null past the end, which is what a click below the last row is.
    pub fn visibleAt(self: *const Tree, wanted: usize) ?*const Node {
        var seen: usize = 0;
        var found: ?*const Node = null;
        const Finder = struct {
            wanted: usize,
            seen: *usize,
            found: *?*const Node,
            fn visit(finder: *@This(), node: *const Node) anyerror!void {
                if (finder.seen.* == finder.wanted) finder.found.* = node;
                finder.seen.* += 1;
            }
        };
        var finder: Finder = .{ .wanted = wanted, .seen = &seen, .found = &found };
        self.visit(&finder, Finder.visit) catch return null;
        return found;
    }

    pub fn count(self: *const Tree) usize {
        return self.nodes.items.len;
    }
};

test "a flat list becomes folders with files inside them" {
    const a = std.testing.allocator;
    var tree = Tree.init(a);
    defer tree.deinit();
    var first = [_][]const u8{"src/a.zig"};
    try tree.rebuild(&first);
    // src is the only row until it is opened, and then a.zig appears under it.
    var rows: usize = 0;
    const Counter = struct {
        fn visit(counter: *usize, node: *const Node) anyerror!void {
            counter.* += 1;
            try std.testing.expect(!node.folder or std.mem.eql(u8, node.name, "src"));
        }
    };
    rows = 0;
    try tree.visit(&rows, Counter.visit);
    try std.testing.expectEqual(@as(usize, 1), rows);

    try tree.expand("src");
    rows = 0;
    try tree.visit(&rows, Counter.visit);
    try std.testing.expectEqual(@as(usize, 2), rows);
    try std.testing.expect(tree.isExpanded("src"));

    try tree.toggle("src");
    try std.testing.expect(!tree.isExpanded("src"));
}

test "siblings are folders first, then names in order" {
    const a = std.testing.allocator;
    var tree = Tree.init(a);
    defer tree.deinit();
    const paths = [_][]const u8{ "readme.md", "src/a.zig", "docs/guide.md", "build.zig" };
    try tree.rebuild(&paths);
    try tree.expand("src");
    try tree.expand("docs");
    var names: [16][]const u8 = undefined;
    var count: usize = 0;
    const State = struct {
        names: *[16][]const u8,
        count: *usize,
        fn visit(self: *@This(), node: *const Node) anyerror!void {
            self.names[self.count.*] = node.name;
            self.count.* += 1;
        }
    };
    var state: State = .{ .names = &names, .count = &count };
    try tree.visit(&state, State.visit);
    // Depth first: a folder, then what is inside it, which is what a tree does
    // and what a reader expects a folder to mean.
    try std.testing.expectEqualStrings("docs", names[0]);
    try std.testing.expectEqualStrings("guide.md", names[1]);
    try std.testing.expectEqualStrings("src", names[2]);
    try std.testing.expectEqualStrings("a.zig", names[3]);
    try std.testing.expectEqualStrings("build.zig", names[4]);
    try std.testing.expectEqualStrings("readme.md", names[5]);
    try std.testing.expectEqual(@as(usize, 6), count);
}

test "a folder inside a collapsed folder stays hidden" {
    const a = std.testing.allocator;
    var tree = Tree.init(a);
    defer tree.deinit();
    const paths = [_][]const u8{"src/gpu/inner.zig"};
    try tree.rebuild(&paths);
    // gpu is open but src is not, so nothing under src is drawn.
    try tree.expand("src/gpu");
    var rows: usize = 0;
    const Counter = struct {
        fn visit(counter: *usize, _: *const Node) anyerror!void {
            counter.* += 1;
        }
    };
    rows = 0;
    try tree.visit(&rows, Counter.visit);
    try std.testing.expectEqual(@as(usize, 1), rows);

    try tree.expand("src");
    rows = 0;
    try tree.visit(&rows, Counter.visit);
    try std.testing.expectEqual(@as(usize, 3), rows);
}
