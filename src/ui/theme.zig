//! The editor's colours, and the theme document that sets them.
//!
//! A draw call names the role it wants - `theme.muted`, `theme.panel` - never a
//! literal colour, and the roles are variables rather than constants because a
//! theme is a runtime choice: `apply` is the one place that changes them, so
//! loading a theme repaints the whole interface without a single call site
//! being touched. `current` carries the same theme as a document, which is what
//! the syntax side resolves a scope name against.
//!
//! The document is the format every importer lands in: JSON, holding the chrome
//! roles, the terminal palette, and syntax rules written as TextMate scope
//! selectors. A key that is absent keeps the default below, so a document may
//! be two colours or a full theme.
//!
//! Colours are `#rgb`, `#rrggbb`, or `#rrggbbaa` in the document and `[4]f32`
//! in the renderer: straight, not premultiplied, with the alpha included.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Color = [4]f32;

/// One colour from 0xRRGGBB, opaque. The components stay straight, which is
/// what the renderer's vertex stage expects.
pub fn rgb(value: u24) Color {
    return fromBytes(@truncate(value >> 16), @truncate(value >> 8), @truncate(value), 255);
}

/// One colour from `#rgb`, `#rrggbb`, or `#rrggbbaa`, or null when the text is
/// not a colour. Published because a theme imported from another editor's file
/// spells its colours the same way.
pub fn colorFromHex(hex: []const u8) ?Color {
    if (hex.len < 2 or hex[0] != '#') return null;
    const digits = hex[1..];
    return switch (digits.len) {
        3 => nibbles: {
            const value = std.fmt.parseInt(u12, digits, 16) catch return null;
            break :nibbles fromBytes(spread(@truncate((value >> 8) & 0xf)), spread(@truncate((value >> 4) & 0xf)), spread(@truncate(value & 0xf)), 255);
        },
        6 => six: {
            const value = std.fmt.parseInt(u24, digits, 16) catch return null;
            break :six fromBytes(@truncate(value >> 16), @truncate(value >> 8), @truncate(value), 255);
        },
        8 => eight: {
            const value = std.fmt.parseInt(u32, digits, 16) catch return null;
            break :eight fromBytes(@truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value));
        },
        else => null,
    };
}

/// A nibble written as its whole byte: `f` is the same colour as `ff`.
fn spread(nibble: u8) u8 {
    return nibble | (nibble << 4);
}

fn fromBytes(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ component(r), component(g), component(b), component(a) };
}

fn component(byte: u8) f32 {
    return @as(f32, @floatFromInt(byte)) / 255;
}

const default_name = "seggs";
const default_background: Color = rgb(0x101216);
const default_panel: Color = rgb(0x16191f);
const default_raised: Color = rgb(0x1d222b);
const default_selected: Color = rgb(0x263b36);
const default_border: Color = rgb(0x2b3039);
const default_text: Color = rgb(0xdce2ed);
const default_muted: Color = rgb(0x8c97aa);
const default_accent: Color = rgb(0x8ee8b4);
const default_purple: Color = rgb(0xc6a0f6);
const default_amber: Color = rgb(0xf5c57d);
const default_red: Color = rgb(0xf38ba8);
const default_blue: Color = rgb(0x91b9ff);
/// Diff colours, deliberately louder and less pastel than the palette's own
/// green and red: an added line should not read as a keyword, and a removed one
/// should not read as a warning. These are the two roles the interface needs
/// that no editor theme file carries.
const default_added: Color = rgb(0x7ee787);
const default_removed: Color = rgb(0xff7b72);

/// The palette every draw call reads. These are variables rather than constants
/// because a theme is a runtime choice, and they keep their names so a site
/// that draws text says `theme.text` and means it under any theme. `apply` is
/// the only writer.
pub var background: Color = default_background;
pub var panel: Color = default_panel;
pub var raised: Color = default_raised;
pub var selected: Color = default_selected;
pub var border: Color = default_border;
pub var text: Color = default_text;
pub var muted: Color = default_muted;
pub var accent: Color = default_accent;
pub var purple: Color = default_purple;
pub var amber: Color = default_amber;
pub var red: Color = default_red;
pub var blue: Color = default_blue;
/// A diff's added and removed lines, kept away from `accent` and `red`: a diff
/// is read for what changed, and borrowing the accent makes every added line
/// shout in the same voice as everything else that is highlighted.
pub var added: Color = default_added;
pub var removed: Color = default_removed;

/// The interface's roles, one field per palette name above and named the same,
/// so `apply` is a straight list and a document names roles rather than hex
/// values. Every field defaults to the colour the editor shipped with, which is
/// what a document leaves out.
pub const Chrome = struct {
    background: Color = default_background,
    panel: Color = default_panel,
    raised: Color = default_raised,
    selected: Color = default_selected,
    border: Color = default_border,
    text: Color = default_text,
    muted: Color = default_muted,
    accent: Color = default_accent,
    purple: Color = default_purple,
    amber: Color = default_amber,
    red: Color = default_red,
    blue: Color = default_blue,
    /// A diff's added and removed lines. No editor theme names these - they are
    /// ours, because a transcript is where diffs turn up - so an imported theme
    /// leaves them at these defaults rather than telling us something wrong.
    added: Color = default_added,
    removed: Color = default_removed,
};

/// What a terminal needs: its own background and foreground, the cursor and
/// selection, and the sixteen ANSI colours. The defaults are the fallbacks the
/// dock uses today - the editor's background and text, the editor's selection,
/// and an ANSI table filled with the background, because a real emulator
/// answers with its own colours and this table only covers the case where it
/// cannot answer at all.
pub const Palette = struct {
    background: Color = default_background,
    foreground: Color = default_text,
    cursor: Color = default_text,
    selection: Color = default_selected,
    ansi: [ansi_colors]Color = @splat(default_background),
};

/// The number of ANSI colours a terminal palette holds.
pub const ansi_colors = 16;

/// One syntax rule: a selector, and the style it gives the scopes it names.
///
/// `selector` is a TextMate selector - comma-separated alternatives of
/// dot-separated scope names, an element prefixed with `-` (or preceded by a
/// lone `-`) to exclude, and a trailing space meaning "this scope and
/// everything under it". `scopeMatch` says which names a selector matches, and
/// the corners it does not implement.
///
/// Only the fields a rule sets are recorded: `bold: false` means "not set"
/// rather than "off", which is what lets a later colour-only rule leave an
/// earlier rule's weight alone.
pub const Scope = struct {
    selector: []const u8,
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    italic: bool = false,
};

/// A theme as the renderer uses it. `name` and the selectors in `syntax` are
/// borrowed: `parse` allocates them with the caller's allocator and `deinit`
/// gives them back, while `defaults()` and a theme an importer builds from its
/// own literals own nothing.
pub const Theme = struct {
    name: []const u8,
    chrome: Chrome = .{},
    syntax: []const Scope = &.{},
    terminal: Palette = .{},
};

/// Today's palette, so an editor with no theme loaded looks exactly as it does
/// now: `apply(defaults())` changes nothing.
pub fn defaults() Theme {
    return .{ .name = default_name, .chrome = .{}, .syntax = &.{}, .terminal = .{} };
}

/// The theme in force. The palette variables above are what draw calls read;
/// this is the document they came from, which is what a syntax lookup needs.
pub var current: Theme = defaults();

/// Make `t` the theme every draw call reads. One assignment per role, so a role
/// cannot be themed in the document and missed on screen.
pub fn apply(t: Theme) void {
    background = t.chrome.background;
    panel = t.chrome.panel;
    raised = t.chrome.raised;
    selected = t.chrome.selected;
    border = t.chrome.border;
    text = t.chrome.text;
    muted = t.chrome.muted;
    accent = t.chrome.accent;
    purple = t.chrome.purple;
    amber = t.chrome.amber;
    red = t.chrome.red;
    blue = t.chrome.blue;
    added = t.chrome.added;
    removed = t.chrome.removed;
    current = t;
}

/// The style a scope name resolves to: walk the rules in document order and let
/// each match set the fields it gives, so a later rule overrides an earlier one
/// field by field and a rule that carries only a foreground leaves an earlier
/// rule's weight and background standing.
pub fn styleFor(theme: Theme, scope_name: []const u8) Scope {
    var resolved: Scope = .{ .selector = scope_name };
    for (theme.syntax) |rule| {
        if (!scopeMatch(rule.selector, scope_name)) continue;
        if (rule.fg) |fg| resolved.fg = fg;
        if (rule.bg) |bg| resolved.bg = bg;
        if (rule.bold) resolved.bold = true;
        if (rule.italic) resolved.italic = true;
    }
    return resolved;
}

/// Whether a selector matches a scope name.
///
/// The grammar implemented: a selector is comma-separated alternatives; an
/// alternative is space-separated elements; a plain element matches the name
/// and everything under it, compared at dot boundaries and case-insensitively
/// (`string.quoted` matches `string.quoted` and `string.quoted.double`, not
/// `stringy`); an element prefixed with `-` or `!` excludes what it names, and
/// a lone `-` excludes the element that follows it; and an alternative of
/// nothing but exclusions matches everything else.
///
/// Two corners are not implemented, and a caller should not expect them:
/// TextMate also matches the other way round - a selector deeper than the
/// queried name (`string.quoted.double` against `string`) still matches, at a
/// lower priority than one that names a prefix - and it ranks matches by
/// specificity; here a selector must name a prefix of the queried name, and
/// `styleFor` settles overlaps by document order instead. Parenthesised groups
/// (`(a | b)`) are not parsed. A trailing space is accepted and matches the
/// same set as no trailing space, which is TextMate's common case: this scope
/// and every scope under it.
pub fn scopeMatch(selector: []const u8, name: []const u8) bool {
    if (selector.len == 0 or name.len == 0) return false;
    var alternatives = std.mem.splitScalar(u8, selector, ',');
    while (alternatives.next()) |alternative| {
        if (matchAlternative(alternative, name)) return true;
    }
    return false;
}

fn matchAlternative(alternative: []const u8, name: []const u8) bool {
    var found = false;
    var positive = false;
    var matched = false;
    var excluded = false;
    var negate_next = false;
    var elements = std.mem.tokenizeAny(u8, alternative, " \t");
    while (elements.next()) |element| {
        var body = element;
        var negated = negate_next;
        negate_next = false;
        // `-string.quoted` excludes; a lone `-` excludes whatever follows it,
        // which is how a selector written with a space between the two reads.
        while (body.len > 0 and (body[0] == '-' or body[0] == '!')) {
            negated = !negated;
            body = body[1..];
        }
        if (body.len == 0) {
            negate_next = negated;
            continue;
        }
        found = true;
        if (!negated) positive = true;
        if (matchesScopeName(body, name)) {
            if (negated) excluded = true else matched = true;
        }
    }
    if (!found or excluded) return false;
    return matched or !positive;
}

fn matchesScopeName(element: []const u8, name: []const u8) bool {
    if (name.len < element.len) return false;
    if (name.len > element.len and name[element.len] != '.') return false;
    return std.ascii.eqlIgnoreCase(name[0..element.len], element);
}

/// The largest document `parse` reads. A theme is a few kilobytes; the bound is
/// here so a wrong path or a corrupt file cannot become a large allocation.
pub const max_document_bytes = 1 << 20;

/// The most syntax rules a document may carry.
pub const max_rules = 4096;

/// Read the native theme document. A key that is absent keeps the default; a
/// key whose value has the wrong shape, a colour that is not a colour, and a
/// document that is not JSON are errors, each with its own name.
///
/// The returned theme owns its name and selectors and must be given back with
/// `deinit`.
pub fn parse(a: Allocator, bytes: []const u8) !Theme {
    if (bytes.len > max_document_bytes) return error.ThemeTooLarge;

    var document = std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = max_document_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedJson,
    };
    defer document.deinit();

    const root = switch (document.value) {
        .object => |object| object,
        else => return error.InvalidDocument,
    };

    var theme: Theme = defaults();
    theme.name = try a.dupe(u8, default_name);
    errdefer a.free(theme.name);

    if (root.get("name")) |value| {
        const theme_name = switch (value) {
            .string => |raw| raw,
            else => return error.InvalidName,
        };
        // An unnamed theme is a document that lost its name, not a theme called
        // nothing, so it keeps the default.
        if (theme_name.len > 0) {
            const copy = try a.dupe(u8, theme_name);
            a.free(theme.name);
            theme.name = copy;
        }
    }
    if (root.get("chrome")) |value| theme.chrome = try parseChrome(value);
    if (root.get("terminal")) |value| theme.terminal = try parsePalette(value);
    // Last, because it is the only key that allocates a list: an error after it
    // would need a second errdefer for the rules.
    if (root.get("syntax")) |value| theme.syntax = try parseRules(a, value);
    return theme;
}

/// Give back what `parse` allocated: the name, the rules, and their selectors.
pub fn deinit(theme: Theme, a: Allocator) void {
    for (theme.syntax) |rule| a.free(rule.selector);
    if (theme.syntax.len > 0) a.free(theme.syntax);
    a.free(theme.name);
}

fn parseChrome(value: std.json.Value) !Chrome {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidChrome,
    };
    var chrome: Chrome = .{};
    // One line per role, in the order the fields are declared.
    if (object.get("background")) |colour| chrome.background = try parseColor(colour);
    if (object.get("panel")) |colour| chrome.panel = try parseColor(colour);
    if (object.get("raised")) |colour| chrome.raised = try parseColor(colour);
    if (object.get("selected")) |colour| chrome.selected = try parseColor(colour);
    if (object.get("border")) |colour| chrome.border = try parseColor(colour);
    if (object.get("text")) |colour| chrome.text = try parseColor(colour);
    if (object.get("muted")) |colour| chrome.muted = try parseColor(colour);
    if (object.get("accent")) |colour| chrome.accent = try parseColor(colour);
    if (object.get("purple")) |colour| chrome.purple = try parseColor(colour);
    if (object.get("amber")) |colour| chrome.amber = try parseColor(colour);
    if (object.get("red")) |colour| chrome.red = try parseColor(colour);
    if (object.get("blue")) |colour| chrome.blue = try parseColor(colour);
    if (object.get("added")) |colour| chrome.added = try parseColor(colour);
    if (object.get("removed")) |colour| chrome.removed = try parseColor(colour);
    return chrome;
}

fn parsePalette(value: std.json.Value) !Palette {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidTerminal,
    };
    var palette: Palette = .{};
    if (object.get("background")) |colour| palette.background = try parseColor(colour);
    if (object.get("foreground")) |colour| palette.foreground = try parseColor(colour);
    if (object.get("cursor")) |colour| palette.cursor = try parseColor(colour);
    if (object.get("selection")) |colour| palette.selection = try parseColor(colour);
    if (object.get("ansi")) |value_ansi| {
        const array = switch (value_ansi) {
            .array => |array| array,
            else => return error.InvalidPalette,
        };
        if (array.items.len != ansi_colors) return error.InvalidPalette;
        for (array.items, 0..) |colour, index| palette.ansi[index] = try parseColor(colour);
    }
    return palette;
}

fn parseRules(a: Allocator, value: std.json.Value) ![]const Scope {
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidSyntax,
    };
    if (array.items.len > max_rules) return error.TooManyRules;

    var rules: std.ArrayListUnmanaged(Scope) = .empty;
    errdefer {
        for (rules.items) |rule| a.free(rule.selector);
        rules.deinit(a);
    }
    try rules.ensureTotalCapacity(a, array.items.len);
    for (array.items) |item| try rules.append(a, try parseRule(a, item));
    return try rules.toOwnedSlice(a);
}

fn parseRule(a: Allocator, value: std.json.Value) !Scope {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidRule,
    };
    const selector = switch (object.get("scope") orelse return error.RuleWithoutScope) {
        .string => |raw| raw,
        else => return error.RuleWithoutScope,
    };
    if (selector.len == 0) return error.RuleWithoutScope;

    var rule: Scope = .{ .selector = try a.dupe(u8, selector) };
    errdefer a.free(rule.selector);
    if (object.get("fg")) |fg| rule.fg = try parseColor(fg);
    if (object.get("bg")) |bg| rule.bg = try parseColor(bg);
    if (object.get("bold")) |bold| rule.bold = try parseFlag(bold);
    if (object.get("italic")) |italic| rule.italic = try parseFlag(italic);
    return rule;
}

fn parseColor(value: std.json.Value) !Color {
    const hex = switch (value) {
        .string => |raw| raw,
        else => return error.InvalidColor,
    };
    return colorFromHex(hex) orelse error.InvalidColor;
}

fn parseFlag(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidRule,
    };
}

const testing = std.testing;

fn expectSameColor(want: Color, got: Color) !void {
    for (want, got) |want_component, got_component| try testing.expectEqual(want_component, got_component);
}

fn expectSameTheme(want: Theme, got: Theme) !void {
    try testing.expectEqualStrings(want.name, got.name);
    try expectSameColor(want.chrome.background, got.chrome.background);
    try expectSameColor(want.chrome.panel, got.chrome.panel);
    try expectSameColor(want.chrome.raised, got.chrome.raised);
    try expectSameColor(want.chrome.selected, got.chrome.selected);
    try expectSameColor(want.chrome.border, got.chrome.border);
    try expectSameColor(want.chrome.text, got.chrome.text);
    try expectSameColor(want.chrome.muted, got.chrome.muted);
    try expectSameColor(want.chrome.accent, got.chrome.accent);
    try expectSameColor(want.chrome.purple, got.chrome.purple);
    try expectSameColor(want.chrome.amber, got.chrome.amber);
    try expectSameColor(want.chrome.red, got.chrome.red);
    try expectSameColor(want.chrome.blue, got.chrome.blue);
    try expectSameColor(want.terminal.background, got.terminal.background);
    try expectSameColor(want.terminal.foreground, got.terminal.foreground);
    try expectSameColor(want.terminal.cursor, got.terminal.cursor);
    try expectSameColor(want.terminal.selection, got.terminal.selection);
    for (want.terminal.ansi, got.terminal.ansi) |want_ansi, got_ansi| try expectSameColor(want_ansi, got_ansi);
    try testing.expectEqual(want.syntax.len, got.syntax.len);
    for (want.syntax, got.syntax) |want_rule, got_rule| {
        try testing.expectEqualStrings(want_rule.selector, got_rule.selector);
        try testing.expectEqual(want_rule.bold, got_rule.bold);
        try testing.expectEqual(want_rule.italic, got_rule.italic);
    }
}

test "the default theme round-trips through a document" {
    const document =
        \\{
        \\  "name": "seggs",
        \\  "chrome": {
        \\    "background": "#101216", "panel": "#16191f", "raised": "#1d222b",
        \\    "selected": "#263b36", "border": "#2b3039", "text": "#dce2ed",
        \\    "muted": "#8c97aa", "accent": "#8ee8b4", "purple": "#c6a0f6",
        \\    "amber": "#f5c57d", "red": "#f38ba8", "blue": "#91b9ff",
        \\    "added": "#7ee787", "removed": "#ff7b72"
        \\  },
        \\  "terminal": {
        \\    "background": "#101216", "foreground": "#dce2ed",
        \\    "cursor": "#dce2ed", "selection": "#263b36",
        \\    "ansi": [
        \\      "#101216", "#101216", "#101216", "#101216",
        \\      "#101216", "#101216", "#101216", "#101216",
        \\      "#101216", "#101216", "#101216", "#101216",
        \\      "#101216", "#101216", "#101216", "#101216"
        \\    ]
        \\  },
        \\  "syntax": []
        \\}
    ;
    const theme = try parse(testing.allocator, document);
    defer deinit(theme, testing.allocator);

    try expectSameTheme(defaults(), theme);
}

test "the three colour spellings parse to their components" {
    const document =
        \\{ "chrome": { "background": "#123", "panel": "#102030", "raised": "#10203040" } }
    ;
    const theme = try parse(testing.allocator, document);
    defer deinit(theme, testing.allocator);

    try expectSameColor(rgb(0x112233), theme.chrome.background);
    try expectSameColor(rgb(0x102030), theme.chrome.panel);
    try expectSameColor(fromBytes(0x10, 0x20, 0x30, 0x40), theme.chrome.raised);
    // A key left out keeps the colour the editor shipped with.
    try expectSameColor(rgb(0xdce2ed), theme.chrome.text);

    try testing.expectError(error.InvalidColor, parse(testing.allocator, "{\"chrome\": {\"text\": \"nope\"}}"));
    try testing.expectError(error.InvalidColor, parse(testing.allocator, "{\"chrome\": {\"text\": \"#12345\"}}"));
    try testing.expectError(error.InvalidColor, parse(testing.allocator, "{\"chrome\": {\"text\": 5}}"));
}

test "a scope selector matches deeper scopes and not unrelated ones" {
    try testing.expect(scopeMatch("string.quoted", "string.quoted.double"));
    try testing.expect(scopeMatch("string.quoted ", "string.quoted.double"));
    try testing.expect(scopeMatch("string", "string"));
    try testing.expect(scopeMatch("STRING.QUOTED", "string.quoted.double"));
    try testing.expect(scopeMatch("keyword.control, string", "string.quoted"));

    try testing.expect(!scopeMatch("string.quoted", "keyword.control"));
    try testing.expect(!scopeMatch("string", "stringy"));
    // The corner the editor does not implement: a selector deeper than the name
    // it is asked about.
    try testing.expect(!scopeMatch("string.quoted.double", "string"));

    try testing.expect(scopeMatch("string - string.quoted", "string.other"));
    try testing.expect(!scopeMatch("string - string.quoted", "string.quoted.double"));
}

test "later rules override earlier ones field by field" {
    const document =
        \\{ "syntax": [
        \\  { "scope": "keyword", "fg": "#f38ba8", "bold": true },
        \\  { "scope": "keyword.control", "fg": "#8ee8b4" }
        \\] }
    ;
    const theme = try parse(testing.allocator, document);
    defer deinit(theme, testing.allocator);

    const control = styleFor(theme, "keyword.control");
    try expectSameColor(rgb(0x8ee8b4), control.fg.?);
    try testing.expect(control.bold);
    try testing.expect(control.bg == null);

    // The earlier rule still owns scopes the later one does not name.
    const operator = styleFor(theme, "keyword.operator");
    try expectSameColor(rgb(0xf38ba8), operator.fg.?);
    try testing.expect(operator.bold);
    try testing.expect(styleFor(theme, "string.quoted").fg == null);
}

test "apply moves every role the palette names" {
    var themed: Theme = defaults();
    themed.name = "testing";
    themed.chrome = .{
        .background = rgb(0x010203),
        .panel = rgb(0x020304),
        .raised = rgb(0x030405),
        .selected = rgb(0x040506),
        .border = rgb(0x050607),
        .text = rgb(0x060708),
        .muted = rgb(0x070809),
        .accent = rgb(0x08090a),
        .purple = rgb(0x090a0b),
        .amber = rgb(0x0a0b0c),
        .red = rgb(0x0b0c0d),
        .blue = rgb(0x0c0d0e),
    };
    apply(themed);
    defer apply(defaults());

    const loaded = [_]struct { want: Color, got: Color }{
        .{ .want = themed.chrome.background, .got = background },
        .{ .want = themed.chrome.panel, .got = panel },
        .{ .want = themed.chrome.raised, .got = raised },
        .{ .want = themed.chrome.selected, .got = selected },
        .{ .want = themed.chrome.border, .got = border },
        .{ .want = themed.chrome.text, .got = text },
        .{ .want = themed.chrome.muted, .got = muted },
        .{ .want = themed.chrome.accent, .got = accent },
        .{ .want = themed.chrome.purple, .got = purple },
        .{ .want = themed.chrome.amber, .got = amber },
        .{ .want = themed.chrome.red, .got = red },
        .{ .want = themed.chrome.blue, .got = blue },
    };
    for (loaded) |role| try expectSameColor(role.want, role.got);
    try testing.expectEqualStrings("testing", current.name);

    // Applying the default theme puts every role back where it started.
    apply(defaults());
    const shipped = [_]struct { want: Color, got: Color }{
        .{ .want = defaults().chrome.background, .got = background },
        .{ .want = defaults().chrome.panel, .got = panel },
        .{ .want = defaults().chrome.raised, .got = raised },
        .{ .want = defaults().chrome.selected, .got = selected },
        .{ .want = defaults().chrome.border, .got = border },
        .{ .want = defaults().chrome.text, .got = text },
        .{ .want = defaults().chrome.muted, .got = muted },
        .{ .want = defaults().chrome.accent, .got = accent },
        .{ .want = defaults().chrome.purple, .got = purple },
        .{ .want = defaults().chrome.amber, .got = amber },
        .{ .want = defaults().chrome.red, .got = red },
        .{ .want = defaults().chrome.blue, .got = blue },
    };
    for (shipped) |role| try expectSameColor(role.want, role.got);
}

test "a document reports each fault under its own name" {
    try testing.expectError(error.MalformedJson, parse(testing.allocator, "{"));
    try testing.expectError(error.InvalidDocument, parse(testing.allocator, "[]"));
    try testing.expectError(error.InvalidName, parse(testing.allocator, "{\"name\": 7}"));
    try testing.expectError(error.InvalidChrome, parse(testing.allocator, "{\"chrome\": []}"));
    try testing.expectError(error.InvalidTerminal, parse(testing.allocator, "{\"terminal\": 1}"));
    try testing.expectError(error.InvalidPalette, parse(testing.allocator, "{\"terminal\": {\"ansi\": [\"#000\"]}}"));
    try testing.expectError(error.InvalidPalette, parse(testing.allocator, "{\"terminal\": {\"ansi\": [\"#000\", \"#000\"]}}"));
    try testing.expectError(error.InvalidSyntax, parse(testing.allocator, "{\"syntax\": {}}"));
    try testing.expectError(error.InvalidRule, parse(testing.allocator, "{\"syntax\": [true]}"));
    try testing.expectError(error.InvalidRule, parse(testing.allocator, "{\"syntax\": [{\"scope\": \"a\", \"bold\": \"yes\"}]}"));
    try testing.expectError(error.RuleWithoutScope, parse(testing.allocator, "{\"syntax\": [{\"fg\": \"#000\"}]}"));
    try testing.expectError(error.InvalidColor, parse(testing.allocator, "{\"syntax\": [{\"scope\": \"a\", \"fg\": \"#00\"}]}"));
}

test "a document larger than the bounds is rejected before it is read" {
    const oversized = try testing.allocator.alloc(u8, max_document_bytes + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try testing.expectError(error.ThemeTooLarge, parse(testing.allocator, oversized));

    var rules: std.ArrayListUnmanaged(u8) = .empty;
    defer rules.deinit(testing.allocator);
    try rules.appendSlice(testing.allocator, "{\"syntax\": [");
    for (0..max_rules + 1) |index| {
        if (index > 0) try rules.append(testing.allocator, ',');
        try rules.appendSlice(testing.allocator, "{\"scope\": \"a\"}");
    }
    try rules.appendSlice(testing.allocator, "]}");
    try testing.expectError(error.TooManyRules, parse(testing.allocator, rules.items));
}
