//! VS Code colour theme importer.
//!
//! A VS Code theme is JSON in three parts. `colors` is a flat map of dotted
//! chrome keys to hex strings, and it is the reason this format earns an
//! importer of its own next to the TextMate reader: it is the one that states
//! what the window around the text looks like instead of leaving that to the
//! editor. `tokenColors` is TextMate scope selectors carrying a style.
//! `semanticTokenColors` is deliberately not read - it is keyed by a semantic
//! tokenizer's token kinds, and this editor classifies tokens lexically, so
//! importing it would colour nothing.
//!
//! Where the two editors do not agree, the importer is partial on purpose: a
//! chrome key with no counterpart here is dropped rather than guessed at, and a
//! terminal palette that is not whole is left alone. A wrong colour that looks
//! themed is worse than the stock one.
const std = @import("std");
const theme = @import("../ui/theme.zig");
const Allocator = std.mem.Allocator;

/// Read a VS Code colour theme into the native document.
///
/// The result owns its name and selectors and is given back with
/// `ui.theme.deinit`, exactly like a theme read from the native format;
/// `ui.theme.apply` is what puts it on screen.
pub fn parse(a: Allocator, bytes: []const u8) !theme.Theme {
    if (bytes.len > theme.max_document_bytes) return error.ThemeTooLarge;

    var document = std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = theme.max_document_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedJson,
    };
    defer document.deinit();

    const root = switch (document.value) {
        .object => |object| object,
        else => return error.InvalidDocument,
    };

    var result: theme.Theme = theme.defaults();

    // The name is duplicated even when the file does not name itself: every
    // theme this returns is entirely allocator-owned, which is what `deinit`
    // assumes.
    var chosen: []const u8 = result.name;
    if (root.get("name")) |value| {
        const written = switch (value) {
            .string => |raw| raw,
            else => return error.InvalidName,
        };
        // A theme that lost its name is not a theme called nothing, so it keeps
        // the default.
        if (written.len > 0) chosen = written;
    }
    result.name = try a.dupe(u8, chosen);
    errdefer a.free(result.name);

    // `colors` is VS Code's whole window, which is more than either editor
    // agrees on; the mapping below is the part that carries over.
    const colors: ?std.json.ObjectMap = if (root.get("colors")) |value| switch (value) {
        .object => |object| object,
        .null => null,
        else => return error.InvalidColors,
    } else null;

    var chrome = result.chrome;
    if (colors) |object| {
        inline for (chrome_map) |entry| {
            if (try colorIn(object, entry.key)) |color| @field(chrome, entry.field) = color;
        }
    }
    result.chrome = chrome;

    if (colors) |object| {
        if (try paletteIn(object)) |palette| result.terminal = palette;
    }

    // Last, because the rules are the only key that allocates a list.
    if (root.get("tokenColors")) |value| result.syntax = try rulesIn(a, value);
    return result;
}

/// The chrome keys with an obvious counterpart, in the order they are applied,
/// so a key written later wins. A key the theme does not set keeps the colour
/// this editor already draws with.
///
/// Everything else in `colors` is dropped rather than guessed at, because it
/// means something this editor does not have: `panel.background`, the
/// statusBar, tab, titleBar, badge, input, list, scrollbar, minimap,
/// breadcrumb, gitDecoration and notification keys, and the editor's own
/// selection, line highlight, ruler, gutter and error colours. `purple` and
/// `blue` are dropped with them even though the palette has both: VS Code
/// spells those keys as token scopes and widget states, not as window roles,
/// and a role filled from a guess is a role themed wrong.
const chrome_map = [_]struct { key: []const u8, field: []const u8 }{
    .{ .key = "editor.background", .field = "background" },
    .{ .key = "editor.foreground", .field = "text" },
    .{ .key = "sideBar.background", .field = "panel" },
    .{ .key = "activityBar.background", .field = "raised" },
    // Both are borders around the body of the window. `panel.border` is the one
    // a reader sees against the editor, so it wins when a theme sets both, and
    // `editorGroup.border` stands in when a theme sets only that one.
    .{ .key = "editorGroup.border", .field = "border" },
    .{ .key = "panel.border", .field = "border" },
    .{ .key = "descriptionForeground", .field = "muted" },
    .{ .key = "focusBorder", .field = "accent" },
};

/// The sixteen ANSI slots in the order `ui.theme.Palette.ansi` holds them: the
/// eight normal colours, then their eight bright counterparts.
const ansi_keys = [theme.ansi_colors][]const u8{
    "terminal.ansiBlack",
    "terminal.ansiRed",
    "terminal.ansiGreen",
    "terminal.ansiYellow",
    "terminal.ansiBlue",
    "terminal.ansiMagenta",
    "terminal.ansiCyan",
    "terminal.ansiWhite",
    "terminal.ansiBrightBlack",
    "terminal.ansiBrightRed",
    "terminal.ansiBrightGreen",
    "terminal.ansiBrightYellow",
    "terminal.ansiBrightBlue",
    "terminal.ansiBrightMagenta",
    "terminal.ansiBrightCyan",
    "terminal.ansiBrightWhite",
};

/// The terminal palette, or null to keep the default one.
///
/// A palette is all sixteen colours plus the two it is drawn on, or it is not a
/// palette: a theme that sets half of them never meant them for a terminal, and
/// filling the rest in would paint a real terminal wrong. Night Owl is the
/// example - it ships all sixteen ANSI keys and no `terminal.background`, so it
/// is left whole rather than applied in half. The cursor and the selection have
/// their own keys; a theme that omits one keeps the default there rather than
/// getting a colour invented for it.
fn paletteIn(object: std.json.ObjectMap) !?theme.Palette {
    const background = (try colorIn(object, "terminal.background")) orelse return null;
    const foreground = (try colorIn(object, "terminal.foreground")) orelse return null;
    var ansi: [theme.ansi_colors]theme.Color = undefined;
    for (ansi_keys, 0..) |key, index| {
        ansi[index] = (try colorIn(object, key)) orelse return null;
    }
    const fallback = theme.defaults().terminal;
    return .{
        .background = background,
        .foreground = foreground,
        .cursor = (try colorIn(object, "terminalCursor.foreground")) orelse fallback.cursor,
        .selection = (try colorIn(object, "terminal.selectionBackground")) orelse fallback.selection,
        .ansi = ansi,
    };
}

/// The `tokenColors` list as syntax rules.
fn rulesIn(a: Allocator, value: std.json.Value) ![]const theme.Scope {
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidTokenColors,
    };
    if (array.items.len > theme.max_rules) return error.TooManyRules;

    var rules: std.ArrayListUnmanaged(theme.Scope) = .empty;
    errdefer {
        for (rules.items) |rule| a.free(rule.selector);
        rules.deinit(a);
    }
    try rules.ensureTotalCapacity(a, array.items.len);
    for (array.items) |entry| {
        if (try ruleIn(a, entry)) |rule| try rules.append(a, rule);
    }
    return try rules.toOwnedSlice(a);
}

/// One `tokenColors` entry as a syntax rule, or null when it has no selector to
/// match with.
fn ruleIn(a: Allocator, value: std.json.Value) !?theme.Scope {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidRule,
    };
    // An entry without a scope is the file's global default: VS Code writes
    // `editor.foreground` for that, which is already the chrome text colour
    // here, and an empty selector matches nothing (`ui.theme.scopeMatch`), so
    // the entry is left out rather than carried as a rule that cannot fire.
    const selector = (try selectorIn(a, object)) orelse return null;
    errdefer a.free(selector);

    var rule: theme.Scope = .{ .selector = selector };
    const settings = if (object.get("settings")) |value_settings| switch (value_settings) {
        .object => |fields| fields,
        else => return error.InvalidRule,
    } else null;
    if (settings) |fields| {
        rule.fg = try colorIn(fields, "foreground");
        rule.bg = try colorIn(fields, "background");
        const style = if (fields.get("fontStyle")) |value_style| switch (value_style) {
            .string => |raw| raw,
            .null => "",
            else => return error.InvalidRule,
        } else "";
        // `fontStyle` is space-separated words: "italic", "bold", "underline",
        // "strikethrough". Only the first two have a slot in the native `Scope`
        // - the decorations are dropped with the rest.
        var words = std.mem.tokenizeScalar(u8, style, ' ');
        while (words.next()) |word| {
            if (std.mem.eql(u8, word, "bold")) rule.bold = true;
            if (std.mem.eql(u8, word, "italic")) rule.italic = true;
        }
    }
    return rule;
}

/// The selector an entry matches with. VS Code writes either one selector or a
/// list of them, and a native `Scope` holds one selector string that
/// `ui.theme.scopeMatch` reads in its comma-separated form, so a list is joined
/// into one: `string.quoted,punctuation.definition.string`.
fn selectorIn(a: Allocator, object: std.json.ObjectMap) !?[]const u8 {
    const value = object.get("scope") orelse return null;
    switch (value) {
        .string => |text| {
            if (text.len == 0) return null;
            return try a.dupe(u8, text);
        },
        .array => |array| {
            var parts: std.ArrayListUnmanaged([]const u8) = .empty;
            defer parts.deinit(a);
            for (array.items) |item| {
                const text = switch (item) {
                    .string => |raw| raw,
                    else => return error.InvalidRule,
                };
                if (text.len > 0) try parts.append(a, text);
            }
            if (parts.items.len == 0) return null;
            return try std.mem.join(a, ",", parts.items);
        },
        .null => return null,
        else => return error.InvalidRule,
    }
}

/// A colour field, parsed. Absent, empty and null all mean the theme does not
/// set the key, which keeps the default: published themes leave keys at null
/// where they do not mean them, and that is not the same as a malformed value.
fn colorIn(object: std.json.ObjectMap, key: []const u8) !?theme.Color {
    const value = object.get(key) orelse return null;
    const text = switch (value) {
        .string => |raw| raw,
        .null => return null,
        else => return error.InvalidColor,
    };
    if (text.len == 0) return null;
    return theme.colorFromHex(text) orelse error.InvalidColor;
}

const testing = std.testing;
/// The fixture sits beside the tests. The unit test binary runs from wherever
/// `zig build` was invoked - the repository root for `zig build test`, and a
/// directory under it when a checkout is built from a subdirectory - so it is
/// looked for on the way up rather than assumed in one place. A missing fixture
/// fails the test: one that was silently skipped would prove nothing.
const fixture_path = "tests/fixtures/night-owl.json";

fn readFixture(a: Allocator) ![]u8 {
    var dir = std.Io.Dir.cwd();
    var opened = false;
    defer if (opened) dir.close(testing.io);
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (dir.readFileAlloc(testing.io, fixture_path, a, .limited(theme.max_document_bytes))) |bytes| {
            return bytes;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
        const parent = dir.openDir(testing.io, "..", .{}) catch break;
        if (opened) dir.close(testing.io);
        dir = parent;
        opened = true;
    }
    return error.ThemeFixtureMissing;
}

fn expectSameColor(want: theme.Color, got: theme.Color) !void {
    for (want, got) |want_component, got_component| try testing.expectEqual(want_component, got_component);
}

fn expectColor(hex: []const u8, got: theme.Color) !void {
    return expectSameColor(theme.colorFromHex(hex).?, got);
}

test "night owl imports its chrome, its scopes, and its italics" {
    const a = testing.allocator;
    const bytes = try readFixture(a);
    defer a.free(bytes);

    const owl = try parse(a, bytes);
    defer theme.deinit(owl, a);

    try testing.expectEqualStrings("Night Owl", owl.name);

    // The chrome keys that mean the same thing here, at the values the file
    // gives them. Night Owl sets both border keys, and the panel's wins.
    try expectColor("#122d42", owl.chrome.accent);
    try expectColor("#011627", owl.chrome.background);
    try expectColor("#5f7e97", owl.chrome.border);
    try expectColor("#5f7e97", owl.chrome.muted);
    try expectColor("#011627", owl.chrome.panel);
    try expectColor("#011627", owl.chrome.raised);
    try expectColor("#d6deeb", owl.chrome.text);

    // The keys with no counterpart keep the colours the editor draws with: the
    // file carries statusBar.foreground, activityBar.foreground and its own
    // selection, and none of those is a role here.
    const stock = theme.defaults();
    try expectSameColor(stock.chrome.amber, owl.chrome.amber);
    try expectSameColor(stock.chrome.red, owl.chrome.red);
    try expectSameColor(stock.chrome.selected, owl.chrome.selected);

    // Three rules from four entries: the unscoped "Global settings" entry is
    // the file's default, and there is no selector to match it with.
    try testing.expectEqual(@as(usize, 3), owl.syntax.len);
    try testing.expectEqualStrings("comment,punctuation.definition.comment", owl.syntax[0].selector);
    try expectColor("#637777", owl.syntax[0].fg.?);
    try testing.expect(owl.syntax[0].italic);
    try testing.expectEqualStrings("string", owl.syntax[1].selector);
    try expectColor("#ecc48d", owl.syntax[1].fg.?);
    try testing.expect(!owl.syntax[1].italic);
    try testing.expectEqualStrings("constant.numeric,constant.character.numeric", owl.syntax[2].selector);
    // An empty `fontStyle` says nothing rather than saying italic.
    try testing.expect(!owl.syntax[2].italic);

    // Night Owl ships all sixteen ANSI keys and no `terminal.background`, so
    // the palette stays whole rather than being applied in half.
    try expectSameColor(stock.terminal.background, owl.terminal.background);
    try expectSameColor(stock.terminal.foreground, owl.terminal.foreground);
    for (stock.terminal.ansi, owl.terminal.ansi) |want, got| try expectSameColor(want, got);
}

test "a complete terminal palette imports in ANSI order" {
    const document =
        \\{ "name": "Palette",
        \\  "colors": {
        \\    "terminal.background": "#000102",
        \\    "terminal.foreground": "#fdfdfe",
        \\    "terminalCursor.foreground": "#80a4c2",
        \\    "terminal.selectionBackground": "#1b90dd4d",
        \\    "terminal.ansiBlack": "#010101",
        \\    "terminal.ansiRed": "#020202",
        \\    "terminal.ansiGreen": "#030303",
        \\    "terminal.ansiYellow": "#040404",
        \\    "terminal.ansiBlue": "#050505",
        \\    "terminal.ansiMagenta": "#060606",
        \\    "terminal.ansiCyan": "#070707",
        \\    "terminal.ansiWhite": "#080808",
        \\    "terminal.ansiBrightBlack": "#090909",
        \\    "terminal.ansiBrightRed": "#0a0a0a",
        \\    "terminal.ansiBrightGreen": "#0b0b0b",
        \\    "terminal.ansiBrightYellow": "#0c0c0c",
        \\    "terminal.ansiBrightBlue": "#0d0d0d",
        \\    "terminal.ansiBrightMagenta": "#0e0e0e",
        \\    "terminal.ansiBrightCyan": "#0f0f0f",
        \\    "terminal.ansiBrightWhite": "#101010"
        \\  },
        \\  "semanticTokenColors": { "class": "#ff0000" }
        \\}
    ;
    const palette = try parse(testing.allocator, document);
    defer theme.deinit(palette, testing.allocator);

    try expectColor("#000102", palette.terminal.background);
    try expectColor("#fdfdfe", palette.terminal.foreground);
    try expectColor("#80a4c2", palette.terminal.cursor);
    // The alpha byte survives, which is the same `#rrggbbaa` the native
    // document spells.
    try expectColor("#1b90dd4d", palette.terminal.selection);

    // A different colour in every slot, in ANSI order: a slot out of place, and
    // the brights swapped with the normal colours, both fail here.
    try expectColor("#010101", palette.terminal.ansi[0]);
    try expectColor("#020202", palette.terminal.ansi[1]);
    try expectColor("#080808", palette.terminal.ansi[7]);
    try expectColor("#090909", palette.terminal.ansi[8]);
    try expectColor("#101010", palette.terminal.ansi[15]);

    // `semanticTokenColors` is a table for a semantic tokenizer, not syntax to
    // import: it becomes no rules at all.
    try testing.expectEqual(@as(usize, 0), palette.syntax.len);
}

test "a partial terminal palette keeps the default" {
    // A background, a foreground and one ANSI colour is not a palette.
    const document =
        \\{ "colors": { "terminal.background": "#000000", "terminal.foreground": "#ffffff", "terminal.ansiRed": "#ff0000" } }
    ;
    const partial = try parse(testing.allocator, document);
    defer theme.deinit(partial, testing.allocator);

    const stock = theme.defaults();
    try expectSameColor(stock.terminal.background, partial.terminal.background);
    try expectSameColor(stock.terminal.foreground, partial.terminal.foreground);
    for (stock.terminal.ansi, partial.terminal.ansi) |want, got| try expectSameColor(want, got);
}

test "a theme with no rules is still ready to be given back" {
    const a = testing.allocator;
    // Nothing but a name: the rules slice is empty, and a theme from `parse` is
    // allocated all the way through so that `deinit` is safe on it.
    const bare = try parse(a, "{\"name\": \"Bare\", \"type\": \"dark\"}");
    defer theme.deinit(bare, a);
    try testing.expectEqualStrings("Bare", bare.name);
    try testing.expectEqual(@as(usize, 0), bare.syntax.len);

    // A file that names no theme keeps the default name, still owned.
    const unnamed = try parse(a, "{}");
    defer theme.deinit(unnamed, a);
    try testing.expectEqualStrings(theme.defaults().name, unnamed.name);
}

test "a theme file reports each fault under its own name" {
    const a = testing.allocator;
    try testing.expectError(error.MalformedJson, parse(a, "{"));
    try testing.expectError(error.InvalidDocument, parse(a, "[]"));
    try testing.expectError(error.InvalidName, parse(a, "{\"name\": 7}"));
    try testing.expectError(error.InvalidColors, parse(a, "{\"colors\": []}"));
    try testing.expectError(error.InvalidColor, parse(a, "{\"colors\": {\"editor.background\": \"not a colour\"}}"));
    try testing.expectError(error.InvalidColor, parse(a, "{\"colors\": {\"sideBar.background\": 5}}"));
    try testing.expectError(error.InvalidTokenColors, parse(a, "{\"tokenColors\": {}}"));
    try testing.expectError(error.InvalidRule, parse(a, "{\"tokenColors\": [true]}"));
    try testing.expectError(error.InvalidRule, parse(a, "{\"tokenColors\": [{\"scope\": \"a\", \"settings\": []}]}"));
    try testing.expectError(error.InvalidRule, parse(a, "{\"tokenColors\": [{\"scope\": [\"a\", 7]}]}"));
    // A `fontStyle` that is neither a string nor null is a fault, not a style.
    try testing.expectError(error.InvalidRule, parse(a, "{\"tokenColors\": [{\"scope\": \"a\", \"settings\": {\"fontStyle\": 3}}]}"));
}

test "a theme file past the bounds is rejected before it is read" {
    const a = testing.allocator;
    const oversized = try a.alloc(u8, theme.max_document_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try testing.expectError(error.ThemeTooLarge, parse(a, oversized));

    var entries: std.ArrayListUnmanaged(u8) = .empty;
    defer entries.deinit(a);
    try entries.appendSlice(a, "{\"tokenColors\": [");
    for (0..theme.max_rules + 1) |index| {
        if (index > 0) try entries.append(a, ',');
        try entries.appendSlice(a, "{}");
    }
    try entries.appendSlice(a, "]}");
    try testing.expectError(error.TooManyRules, parse(a, entries.items));
}
