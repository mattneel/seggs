const std = @import("std");
const yoga = @import("yoga");
const Renderer = @import("../gpu/renderer.zig").Renderer;
const Color = @import("../ui/theme.zig").Color;
const theme = @import("../ui/theme.zig");

/// Interface described by extensions. An extension returns a plain object and
/// the host turns it into Yoga nodes; nothing about Yoga or the renderer reaches
/// the description, so an extension can be written without knowing either.
///
/// The description is re-read every frame rather than cached, so a panel that
/// depends on live data stays correct without an invalidation protocol.
pub const Node = struct {
    pub const Kind = enum { row, column, box, text };

    /// Optional name an extension uses to identify the node in events.
    id: []const u8 = "",
    kind: Kind = .column,
    /// Leaf content. Only `text` uses it.
    text: []const u8 = "",
    color: Color = theme.text,
    /// Fill drawn behind a container before its children. Null leaves it clear.
    background: ?Color = null,
    style: Style = .{},
    children: []Node = &.{},

    /// Whether the node takes part in keyboard focus order. It should carry an
    /// `id`, which is what an event reports.
    focusable: bool = false,

    /// Set while the tree is built; the layout results live on these.
    yoga_node: ?yoga.YGNodeRef = null,
    /// Cell metrics a measured text leaf reports against.
    metrics: LeafMetrics = .{ .cell_width = 1, .line_height = 1 },

    pub const Style = struct {
        width: ?f32 = null,
        height: ?f32 = null,
        min_width: ?f32 = null,
        max_width: ?f32 = null,
        /// Percentage of the parent's height, for bands that scale.
        height_percent: ?f32 = null,
        grow: f32 = 0,
        shrink: f32 = 0,
        padding: f32 = 0,
        gap: f32 = 0,
        align_items: ?Align = null,
        justify: ?Justify = null,
    };

    pub const Align = enum { start, center, end, stretch };
    pub const Justify = enum { start, center, end, between };

    /// Limits on a description, which is untrusted input from JavaScript.
    pub const max_depth = 16;
    pub const max_nodes = 512;
};

/// Cell metrics a measured leaf reports against.
pub const LeafMetrics = struct { cell_width: f32, line_height: f32 };

/// A description that has been parsed and laid out. One tree owns its Nodes, its
/// Yoga nodes, and every string it copied out of JavaScript.
pub const Tree = struct {
    allocator: std.mem.Allocator,
    root: Node = .{},
    nodes: usize = 0,

    pub fn init(a: std.mem.Allocator) Tree {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Tree) void {
        self.clear();
        self.* = .{ .allocator = self.allocator };
    }

    /// Drop the current tree, keeping the allocator. A caller that re-reads a
    /// panel every frame frees the previous description here.
    pub fn clear(self: *Tree) void {
        if (self.root.yoga_node) |node| yoga.YGNodeFreeRecursive(node);
        freeNode(self.allocator, &self.root);
        self.root = .{};
        self.nodes = 0;
    }

    /// Parse the value an extension returned, replacing any current tree.
    /// Everything is copied, so the caller may free the JSON value afterwards.
    pub fn parse(self: *Tree, value: std.json.Value) !void {
        self.clear();
        self.root = try parseNode(self.allocator, value, 0, &self.nodes);
    }

    /// Build Yoga nodes. The cell metrics come from the atlas, so a measured text
    /// leaf occupies the grid the renderer draws it on.
    pub fn build(self: *Tree, cell_width: f32, line_height: f32) !void {
        self.root.yoga_node = try buildNode(&self.root, .{ .cell_width = cell_width, .line_height = line_height });
    }

    /// Lay the tree out inside the given box, then read results back with
    /// coordinates relative to that box.
    pub fn layout(self: *Tree, width: f32, height: f32) void {
        const node = self.root.yoga_node orelse return;
        yoga.YGNodeCalculateLayout(node, width, height, yoga.YGDirectionLTR);
    }

    /// Draw the laid-out tree through the same quad path as the rest of the
    /// interface, offset by the panel's origin.
    pub fn render(self: *Tree, r: *Renderer, origin_x: f32, origin_y: f32) !void {
        try renderNode(&self.root, r, origin_x, origin_y);
    }

    /// Deepest node containing a point, or null. Used to tell an extension which
    /// of its nodes was clicked.
    pub fn nodeAt(self: *const Tree, x: f32, y: f32, origin_x: f32, origin_y: f32) ?*const Node {
        return findNode(&self.root, x, y, origin_x, origin_y);
    }

    /// A named node and where it was laid out, in the coordinates the caller
    /// passed to `layout`. One pass collects these per frame, which is what hit
    /// testing, hover, and focus order all read.
    pub const Target = struct {
        id: []const u8,
        /// Whether the node takes part in Tab order.
        focusable: bool,
        bounds: struct { x: f32, y: f32, w: f32, h: f32 },
    };

    /// Append every named node in document order, which is also the order Tab
    /// moves through the focusable ones. Bounds are absolute, so a caller needs
    /// no second walk of the tree.
    pub fn collectTargets(self: *const Tree, list: *std.ArrayListUnmanaged(Target), allocator: std.mem.Allocator, origin_x: f32, origin_y: f32) !void {
        try collect(self.root.children, list, allocator, origin_x, origin_y);
    }

    fn collect(children: []const Node, list: *std.ArrayListUnmanaged(Target), allocator: std.mem.Allocator, origin_x: f32, origin_y: f32) !void {
        for (children) |*child| {
            const ref = child.yoga_node orelse continue;
            const x = origin_x + yoga.YGNodeLayoutGetLeft(ref);
            const y = origin_y + yoga.YGNodeLayoutGetTop(ref);
            if (child.id.len > 0) {
                try list.append(allocator, .{
                    .id = child.id,
                    .focusable = child.focusable,
                    .bounds = .{ .x = x, .y = y, .w = yoga.YGNodeLayoutGetWidth(ref), .h = yoga.YGNodeLayoutGetHeight(ref) },
                });
            }
            try collect(child.children, list, allocator, x, y);
        }
    }

    /// Size the tree reported for its containing box, which is what a panel
    /// needs to know when it sizes itself instead of the box.
    pub fn size(self: *const Tree) struct { width: f32, height: f32 } {
        const ref = self.root.yoga_node orelse return .{ .width = 0, .height = 0 };
        return .{ .width = yoga.YGNodeLayoutGetWidth(ref), .height = yoga.YGNodeLayoutGetHeight(ref) };
    }
};

fn parseNode(a: std.mem.Allocator, value: std.json.Value, depth: usize, count: *usize) !Node {
    if (depth > Node.max_depth) return error.DescriptionTooDeep;
    const object = switch (value) {
        .object => |object| object,
        else => return error.DescriptionNotObject,
    };
    if (count.* >= Node.max_nodes) return error.DescriptionTooLarge;
    count.* += 1;

    var node: Node = .{};
    errdefer freeNode(a, &node);
    if (try ownedString(a, object, "id")) |id| node.id = id;
    if (try ownedString(a, object, "text")) |text| node.text = text;
    if (try rawString(object, "type")) |kind| {
        node.kind = std.meta.stringToEnum(Node.Kind, kind) orelse return error.DescriptionBadType;
    }
    if (try rawString(object, "color")) |name| {
        node.color = colorByName(name) orelse return error.DescriptionBadColor;
    }
    if (try rawString(object, "background")) |name| {
        node.background = colorByName(name) orelse return error.DescriptionBadColor;
    }
    node.focusable = booleanField(object, "focusable") orelse false;
    node.style = .{
        .width = numberField(object, "width"),
        .height = numberField(object, "height"),
        .min_width = numberField(object, "minWidth"),
        .max_width = numberField(object, "maxWidth"),
        .height_percent = numberField(object, "heightPercent"),
        .grow = numberField(object, "grow") orelse 0,
        .shrink = numberField(object, "shrink") orelse 0,
        .padding = numberField(object, "padding") orelse 0,
        .gap = numberField(object, "gap") orelse 0,
    };
    if (try rawString(object, "align")) |name| {
        node.style.align_items = std.meta.stringToEnum(Node.Align, name) orelse return error.DescriptionBadAlign;
    }
    if (try rawString(object, "justify")) |name| {
        node.style.justify = std.meta.stringToEnum(Node.Justify, name) orelse return error.DescriptionBadJustify;
    }
    if (object.get("children")) |children_value| {
        const array = switch (children_value) {
            .array => |array| array,
            else => return error.DescriptionBadChildren,
        };
        const children = try a.alloc(Node, array.items.len);
        node.children = children;
        // Zero first so an error part way through leaves every child freeable.
        for (0..children.len) |index| children[index] = .{};
        for (array.items, 0..) |child, index| {
            children[index] = try parseNode(a, child, depth + 1, count);
        }
    }
    return node;
}

/// A string the tree keeps, so it is copied out of the JSON value.
fn ownedString(a: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const text = (try rawString(object, key)) orelse return null;
    return try a.dupe(u8, text);
}

/// A string that is only compared against a table. It is borrowed, because the
/// JSON value outlives parsing and copying it would leak.
fn rawString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => return error.DescriptionBadField,
    };
    if (text.len == 0) return null;
    return text;
}

fn booleanField(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn numberField(object: std.json.ObjectMap, key: []const u8) ?f32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| @floatCast(float),
        .number_string => |text| std.fmt.parseFloat(f32, text) catch null,
        else => null,
    };
}

/// Theme colors by name, so a description never carries raw components and a
/// theme change reaches extension panels too.
fn colorByName(name: []const u8) ?Color {
    const names = [_]struct { name: []const u8, color: Color }{
        .{ .name = "text", .color = theme.text },
        .{ .name = "muted", .color = theme.muted },
        .{ .name = "accent", .color = theme.accent },
        .{ .name = "amber", .color = theme.amber },
        .{ .name = "red", .color = theme.red },
        .{ .name = "blue", .color = theme.blue },
        .{ .name = "purple", .color = theme.purple },
        .{ .name = "panel", .color = theme.panel },
        .{ .name = "raised", .color = theme.raised },
        .{ .name = "selected", .color = theme.selected },
        .{ .name = "border", .color = theme.border },
        .{ .name = "background", .color = theme.background },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.color;
    }
    return null;
}

fn buildNode(node: *Node, metrics: LeafMetrics) !yoga.YGNodeRef {
    const ref = yoga.YGNodeNew() orelse return error.YogaNode;
    errdefer yoga.YGNodeFreeRecursive(ref);
    const style = node.style;
    yoga.YGNodeStyleSetFlexDirection(ref, if (node.kind == .row) yoga.YGFlexDirectionRow else yoga.YGFlexDirectionColumn);
    if (style.width) |value| yoga.YGNodeStyleSetWidth(ref, value);
    if (style.height) |value| yoga.YGNodeStyleSetHeight(ref, value);
    if (style.min_width) |value| yoga.YGNodeStyleSetMinWidth(ref, value);
    if (style.max_width) |value| yoga.YGNodeStyleSetMaxWidth(ref, value);
    if (style.height_percent) |value| yoga.YGNodeStyleSetHeightPercent(ref, value);
    if (style.padding != 0) yoga.YGNodeStyleSetPadding(ref, yoga.YGEdgeAll, style.padding);
    if (style.gap != 0) yoga.YGNodeStyleSetGap(ref, yoga.YGGutterAll, style.gap);
    yoga.YGNodeStyleSetFlexGrow(ref, style.grow);
    yoga.YGNodeStyleSetFlexShrink(ref, style.shrink);
    if (style.align_items) |items| yoga.YGNodeStyleSetAlignItems(ref, alignValue(items));
    if (style.justify) |content| yoga.YGNodeStyleSetJustifyContent(ref, justifyValue(content));

    for (node.children) |*child| {
        const child_ref = try buildNode(child, metrics);
        child.yoga_node = child_ref;
        _ = yoga.YGNodeInsertChild(ref, child_ref, yoga.YGNodeGetChildCount(ref));
    }
    if (node.kind == .text) {
        node.metrics = metrics;
        yoga.YGNodeSetContext(ref, node);
        yoga.YGNodeSetMeasureFunc(ref, measureText);
    }
    return ref;
}

fn alignValue(value: Node.Align) yoga.YGAlign {
    return switch (value) {
        .start => yoga.YGAlignFlexStart,
        .center => yoga.YGAlignCenter,
        .end => yoga.YGAlignFlexEnd,
        .stretch => yoga.YGAlignStretch,
    };
}

fn justifyValue(justify: Node.Justify) yoga.YGJustify {
    return switch (justify) {
        .start => yoga.YGJustifyFlexStart,
        .center => yoga.YGJustifyCenter,
        .end => yoga.YGJustifyFlexEnd,
        .between => yoga.YGJustifySpaceBetween,
    };
}

/// A text leaf reports the grid it occupies: one cell per codepoint, one line
/// per newline. Yoga passes the available space, which a wrapping leaf would use.
fn measureText(node: yoga.YGNodeConstRef, width: f32, width_mode: yoga.YGMeasureMode, height: f32, height_mode: yoga.YGMeasureMode) callconv(.c) yoga.YGSize {
    _ = .{ width, width_mode, height, height_mode };
    const context = yoga.YGNodeGetContext(node) orelse return .{ .width = 0, .height = 0 };
    const payload: *const Node = @ptrCast(@alignCast(context));
    return .{
        .width = @as(f32, @floatFromInt(cellsIn(payload.text))) * payload.metrics.cell_width,
        .height = @as(f32, @floatFromInt(linesIn(payload.text))) * payload.metrics.line_height,
    };
}

fn cellsIn(text: []const u8) usize {
    var cells: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index = nextCodepoint(text, index)) cells += 1;
    return cells;
}

fn linesIn(text: []const u8) usize {
    var lines: usize = 1;
    for (text) |byte| {
        if (byte == '\n') lines += 1;
    }
    return lines;
}

/// Advance past one codepoint, leaving malformed bytes as single cells rather
/// than failing: a description is untrusted input from JavaScript.
fn nextCodepoint(text: []const u8, index: usize) usize {
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return index + 1;
    if (index + length > text.len) return index + 1;
    return index + length;
}

/// Yoga reports each node relative to its parent, so the parent's resolved
/// position is the origin for its children.
fn renderNode(node: *const Node, r: *Renderer, origin_x: f32, origin_y: f32) !void {
    const ref = node.yoga_node orelse return;
    const x = origin_x + yoga.YGNodeLayoutGetLeft(ref);
    const y = origin_y + yoga.YGNodeLayoutGetTop(ref);
    const width = yoga.YGNodeLayoutGetWidth(ref);
    const height = yoga.YGNodeLayoutGetHeight(ref);
    if (node.background) |fill| try r.rect(.{ .x = x, .y = y, .w = width, .h = height }, fill);
    switch (node.kind) {
        .box => try r.rect(.{ .x = x, .y = y, .w = width, .h = height }, node.color),
        .text => try r.text(x, y, node.text, node.color),
        .row, .column => {},
    }
    for (node.children) |*child| try renderNode(child, r, x, y);
}

fn findNode(node: *const Node, x: f32, y: f32, origin_x: f32, origin_y: f32) ?*const Node {
    const ref = node.yoga_node orelse return null;
    const left = origin_x + yoga.YGNodeLayoutGetLeft(ref);
    const top = origin_y + yoga.YGNodeLayoutGetTop(ref);
    if (x < left or y < top or x >= left + yoga.YGNodeLayoutGetWidth(ref) or y >= top + yoga.YGNodeLayoutGetHeight(ref)) return null;
    // Deepest match wins, so a click reports the row inside a panel rather than
    // the panel.
    for (node.children) |*child| {
        if (findNode(child, x, y, left, top)) |hit| return hit;
    }
    return node;
}

fn freeNode(a: std.mem.Allocator, node: *Node) void {
    for (node.children) |*child| freeNode(a, child);
    if (node.children.len > 0) a.free(node.children);
    if (node.text.len > 0) a.free(node.text);
    if (node.id.len > 0) a.free(node.id);
    node.children = &.{};
    node.text = "";
    node.id = "";
}

test "a description lays out rows, measured text, and boxes" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"type":"column","padding":6,"gap":4,"children":[
        \\  {"type":"text","id":"title","text":"AGENTS","color":"accent"},
        \\  {"type":"row","gap":4,"children":[
        \\    {"type":"box","id":"dot","width":8,"height":8,"color":"red"},
        \\    {"type":"text","text":"two","color":"muted"}
        \\  ]}
        \\]}
    , .{});
    defer parsed.deinit();
    var tree = Tree.init(a);
    defer tree.deinit();
    try tree.parse(parsed.value);
    try tree.build(9.5, 22);
    tree.layout(200, 100);

    const size = tree.size();
    try std.testing.expectEqual(@as(f32, 200), size.width);
    // A column stretches its children across the padded width.
    try std.testing.expectApproxEqAbs(@as(f32, 188), yoga.YGNodeLayoutGetWidth(tree.root.children[0].yoga_node.?), 0.01);
    // Inside the row the text is measured instead: three cells of 9.5, starting
    // one gap after the eight-wide box.
    const row = tree.root.children[1].yoga_node.?;
    try std.testing.expectApproxEqAbs(@as(f32, 6), yoga.YGNodeLayoutGetLeft(row), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), yoga.YGNodeLayoutGetLeft(tree.root.children[1].children[0].yoga_node.?), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8), yoga.YGNodeLayoutGetWidth(tree.root.children[1].children[0].yoga_node.?), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 12), yoga.YGNodeLayoutGetLeft(tree.root.children[1].children[1].yoga_node.?), 0.01);
    // Yoga rounds layout to the pixel grid, so three cells of 9.5 measure 29.
    try std.testing.expectApproxEqAbs(@as(f32, 29), yoga.YGNodeLayoutGetWidth(tree.root.children[1].children[1].yoga_node.?), 0.01);
    // Hit testing reports the deepest node, by id, and resolves nested offsets:
    // the box sits at its row's position, not at the panel's.
    try std.testing.expectEqualStrings("title", (tree.nodeAt(10, 10, 0, 0) orelse return error.NoNode).id);
    // The row sits one gap below the title, and the box is at its left edge.
    try std.testing.expectEqualStrings("dot", (tree.nodeAt(7, 36, 0, 0) orelse return error.NoNode).id);
}

test "focusable nodes are collected in order with absolute bounds" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"type":"column","padding":6,"gap":4,"children":[
        \\  {"type":"text","id":"label","text":"x"},
        \\  {"type":"box","id":"one","focusable":true,"width":20,"height":10,"color":"accent"},
        \\  {"type":"row","gap":4,"children":[
        \\    {"type":"box","id":"two","focusable":true,"width":20,"height":10,"color":"accent"},
        \\    {"type":"box","id":"plain","width":20,"height":10,"color":"border"}
        \\  ]}
        \\]}
    , .{});
    defer parsed.deinit();
    var tree = Tree.init(a);
    defer tree.deinit();
    try tree.parse(parsed.value);
    try tree.build(9.5, 22);
    tree.layout(200, 100);

    var targets: std.ArrayListUnmanaged(Tree.Target) = .empty;
    defer targets.deinit(a);
    try tree.collectTargets(&targets, a, 100, 50);
    // Every named node, in document order, with the panel origin folded in and
    // each one saying whether it takes part in Tab order.
    try std.testing.expectEqual(@as(usize, 4), targets.items.len);
    try std.testing.expectEqualStrings("label", targets.items[0].id);
    try std.testing.expect(!targets.items[0].focusable);
    try std.testing.expectEqualStrings("one", targets.items[1].id);
    try std.testing.expect(targets.items[1].focusable);
    try std.testing.expectEqual(@as(f32, 106), targets.items[1].bounds.x);
    try std.testing.expectEqual(@as(f32, 82), targets.items[1].bounds.y);
    try std.testing.expectEqualStrings("two", targets.items[2].id);
    try std.testing.expect(targets.items[2].focusable);
    try std.testing.expectEqual(@as(f32, 106), targets.items[2].bounds.x);
    try std.testing.expectEqual(@as(f32, 96), targets.items[2].bounds.y);
    try std.testing.expectEqualStrings("plain", targets.items[3].id);
    try std.testing.expect(!targets.items[3].focusable);

    // A point inside the second focusable reports it, not its parent row.
    const hit = tree.nodeAt(108, 100, 100, 50) orelse return error.NoNode;
    try std.testing.expectEqualStrings("two", hit.id);
    // A point inside the parent but outside either child reports the parent.
    const between = tree.nodeAt(150, 100, 100, 50) orelse return error.NoNode;
    try std.testing.expectEqualStrings("", between.id);
}

test "a description is rejected when it exceeds its bounds" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"type\":\"not-a-kind\"}", .{});
    defer parsed.deinit();
    var tree = Tree.init(a);
    defer tree.deinit();
    try std.testing.expectError(error.DescriptionBadType, tree.parse(parsed.value));

    var nested = try std.json.parseFromSlice(std.json.Value, a, "{\"type\":\"box\",\"color\":\"nope\"}", .{});
    defer nested.deinit();
    try std.testing.expectError(error.DescriptionBadColor, tree.parse(nested.value));
}
