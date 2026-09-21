//! TextMate `.tmTheme` importer.
//!
//! A `.tmTheme` is an XML property list, and this is a reader for exactly the
//! document shape themes use: a top-level dict carrying `name` and a `settings`
//! array, whose entries name a token scope and the style that scope takes. It
//! is the format Monokai and most classic colour schemes were published in, and
//! it lands in the same native document `ui/theme.zig` parses.
//!
//! Nothing general is attempted: no XML library, no dependency, and no
//! formatting the file does not carry. In particular a tmTheme has no terminal
//! palette - the sixteen ANSI colours are simply not in this format - so the
//! terminal keeps its default rather than being invented.

const std = @import("std");
const theme = @import("../ui/theme.zig");

/// Parse a TextMate theme into the native theme document.
///
/// The name is always a copy, and every rule's selector is a copy, so the
/// returned theme borrows nothing from `bytes`; give it back with
/// `theme.deinit` when `a` is not an arena. Nothing is allocated for the
/// terminal palette: a tmTheme carries no ANSI colours, so `terminal` is the
/// default palette rather than a guess at what the editor's terminal showed.
///
/// Errors are `error.ThemeTooLarge`, `error.TooManyRules`,
/// `error.MalformedTheme`, and `error.InvalidColor`.
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !theme.Theme {
    if (bytes.len > theme.max_document_bytes) return error.ThemeTooLarge;

    // The plist tree is scaffolding: only the theme survives this function.
    // Building it in a scratch arena means a file that turns out to be
    // malformed leaves nothing behind in the allocator the caller keeps.
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temp = scratch.allocator();

    var source = Reader{ .bytes = bytes };
    try source.skipProlog();
    // `<plist version="1.0">` wraps the document and carries no theme data.
    const wrapper = try source.nextTag();
    if (wrapper.empty or !std.mem.eql(u8, wrapper.name, "plist")) return error.MalformedTheme;
    const document = switch (try source.parseValue(temp, 0)) {
        .dict => |entries| entries,
        else => return error.MalformedTheme,
    };
    if (!try source.atClose("plist")) return error.MalformedTheme;
    source.skipPadding();
    if (!source.done()) return error.MalformedTheme;

    const listed_name = try textField(document, "name");

    // A file with no `settings` key is a document without rules rather than a
    // broken one, which is the same way the native parser treats a missing key.
    const settings: []const Value = if (lookup(document, "settings")) |value| switch (value) {
        .array => |items| items,
        else => return error.MalformedTheme,
    } else &.{};
    if (settings.len > theme.max_rules) return error.TooManyRules;

    // The entry with no scope is the editor itself rather than a rule for a
    // token: its `background` and `foreground` are the two editor colours this
    // format carries anywhere. Take those for the chrome and leave every other
    // chrome role at its default, because the file never spoke about them -
    // `caret`, `selection` and `lineHighlight` live in this entry too, and
    // mapping them onto roles with different meanings would be a guess.
    var editor_background: ?theme.Color = null;
    var editor_foreground: ?theme.Color = null;

    var rules: std.ArrayList(theme.Scope) = .empty;
    defer rules.deinit(a);
    errdefer {
        for (rules.items) |rule| a.free(rule.selector);
    }

    for (settings) |item| {
        const entry = switch (item) {
            .dict => |fields| fields,
            else => return error.MalformedTheme,
        };
        const stored = lookup(entry, "settings") orelse continue;
        const style = switch (stored) {
            .dict => |fields| fields,
            else => return error.MalformedTheme,
        };
        const selector = try textField(entry, "scope");
        const fg = try colorField(style, "foreground");
        const bg = try colorField(style, "background");
        if (selector.len == 0) {
            if (bg) |colour| editor_background = colour;
            if (fg) |colour| editor_foreground = colour;
            continue;
        }
        const font_style = try textField(style, "fontStyle");
        const owned = try a.dupe(u8, selector);
        errdefer a.free(owned);
        try rules.append(a, .{
            .selector = owned,
            .fg = fg,
            .bg = bg,
            .bold = styleFlag(font_style, "bold"),
            .italic = styleFlag(font_style, "italic"),
        });
    }

    // Everything the file does not speak about keeps its default, and the
    // terminal is the whole of that here: a tmTheme holds no sixteen ANSI
    // colours, so there is nothing to map and nothing to invent.
    var result = theme.defaults();
    // The name is always a copy, even when the file carries none: `theme.deinit`
    // frees it, and the default name is a literal.
    result.name = try a.dupe(u8, if (listed_name.len > 0) listed_name else result.name);
    errdefer a.free(result.name);

    result.syntax = try rules.toOwnedSlice(a);
    errdefer {
        for (result.syntax) |rule| a.free(rule.selector);
        if (result.syntax.len > 0) a.free(result.syntax);
    }

    if (editor_background) |colour| result.chrome.background = colour;
    if (editor_foreground) |colour| result.chrome.text = colour;
    return result;
}

/// The string a key holds, or empty when the key is absent. A key holding
/// something other than a string is malformed: every key read here holds one.
fn textField(entries: []const Entry, key: []const u8) ![]const u8 {
    const value = lookup(entries, key) orelse return "";
    return switch (value) {
        .string => |text| text,
        else => error.MalformedTheme,
    };
}

fn colorField(entries: []const Entry, key: []const u8) !?theme.Color {
    const value = lookup(entries, key) orelse return null;
    const text = switch (value) {
        .string => |raw| raw,
        else => return error.MalformedTheme,
    };
    // Trimmed because a hand-edited theme can carry whitespace inside the tag,
    // but not otherwise forgiven: `#rgb`, `#rrggbb` and `#rrggbbaa` are the
    // whole vocabulary, and a value outside it is a mistake worth reporting
    // rather than a colour that silently reads as black.
    return theme.colorFromHex(std.mem.trim(u8, text, " \t\r\n")) orelse error.InvalidColor;
}

/// `fontStyle` lists `bold`, `italic` and `underline`, comma- or
/// space-separated. A scope has no underline, so that one is dropped rather
/// than approximated by a weight it is not.
fn styleFlag(font_style: []const u8, flag: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, font_style, ", \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, flag)) return true;
    }
    return false;
}

fn lookup(entries: []const Entry, key: []const u8) ?Value {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

/// The text XML allows in a plist string. Text without an `&` is handed back as
/// it lies in the document; only text that needs decoding is copied.
fn decodeEntities(scratch: std.mem.Allocator, raw: []const u8) ReadError![]const u8 {
    var at = std.mem.indexOfScalar(u8, raw, '&') orelse return raw;
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(scratch);
    try decoded.appendSlice(scratch, raw[0..at]);
    while (at < raw.len) {
        const next = std.mem.indexOfScalarPos(u8, raw, at, '&') orelse {
            try decoded.appendSlice(scratch, raw[at..]);
            break;
        };
        try decoded.appendSlice(scratch, raw[at..next]);
        const semi = std.mem.indexOfScalarPos(u8, raw, next, ';') orelse return error.MalformedTheme;
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(try entity(raw[next + 1 .. semi]), &encoded) catch return error.MalformedTheme;
        try decoded.appendSlice(scratch, encoded[0..length]);
        at = semi + 1;
    }
    return decoded.toOwnedSlice(scratch);
}

fn entity(body: []const u8) error{MalformedTheme}!u21 {
    if (std.mem.eql(u8, body, "amp")) return '&';
    if (std.mem.eql(u8, body, "lt")) return '<';
    if (std.mem.eql(u8, body, "gt")) return '>';
    if (std.mem.eql(u8, body, "quot")) return '"';
    if (std.mem.eql(u8, body, "apos")) return '\'';
    if (body.len > 1 and body[0] == '#') {
        const is_hex = body[1] == 'x' or body[1] == 'X';
        const digits = if (is_hex) body[2..] else body[1..];
        if (digits.len == 0) return error.MalformedTheme;
        return std.fmt.parseInt(u21, digits, if (is_hex) 16 else 10) catch error.MalformedTheme;
    }
    return error.MalformedTheme;
}

/// A plist value. `other` is a scalar this importer does not read - integer,
/// real, date, data, or a boolean - and is kept rather than rejected, because a
/// theme may carry a key nobody here reads.
const Value = union(enum) {
    string: []const u8,
    array: []Value,
    dict: []Entry,
    other,
};

const Entry = struct { key: []const u8, value: Value };

const Tag = struct { name: []const u8, empty: bool };

/// Everything the reader fails with: a document that is not the plist shape it
/// was built for, or the scratch allocator giving up. Spelled out because
/// `parseValue` and `parseDict` would otherwise infer each other's error sets.
const ReadError = error{MalformedTheme} || std.mem.Allocator.Error;

/// Walks the document once, left to right. The reader never copies: the strings
/// it returns point into `bytes` unless they carried an entity reference, whose
/// copy is made in the caller's scratch allocator.
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn done(self: *const Reader) bool {
        return self.at >= self.bytes.len;
    }

    fn rest(self: *const Reader) []const u8 {
        return self.bytes[@min(self.at, self.bytes.len)..];
    }

    /// Whitespace and comments between elements carry no meaning.
    fn skipPadding(self: *Reader) void {
        while (self.at < self.bytes.len) {
            if (std.ascii.isWhitespace(self.bytes[self.at])) {
                self.at += 1;
            } else if (std.mem.startsWith(u8, self.rest(), "<!--")) {
                const close = std.mem.indexOf(u8, self.rest(), "-->") orelse {
                    self.at = self.bytes.len;
                    return;
                };
                self.at += close + 3;
            } else return;
        }
    }

    /// The XML declaration and the doctype, when the writer emitted them.
    fn skipProlog(self: *Reader) ReadError!void {
        if (std.mem.startsWith(u8, self.bytes, "\xEF\xBB\xBF")) self.at = 3;
        while (true) {
            self.skipPadding();
            const text = self.rest();
            if (std.mem.startsWith(u8, text, "<?")) {
                const close = std.mem.indexOf(u8, text, "?>") orelse return error.MalformedTheme;
                self.at += close + 2;
            } else if (std.mem.startsWith(u8, text, "<!")) {
                const close = std.mem.indexOfScalar(u8, text, '>') orelse return error.MalformedTheme;
                self.at += close + 1;
            } else return;
        }
    }

    /// Consume the next tag and name it. Attributes are skipped; only
    /// `<plist version="1.0">` has any.
    fn nextTag(self: *Reader) ReadError!Tag {
        self.skipPadding();
        const text = self.rest();
        if (text.len == 0 or text[0] != '<') return error.MalformedTheme;
        // A closing tag carries a `/` that is syntax rather than name, and it
        // is also the delimiter that would otherwise end the name at once.
        const start: usize = if (text.len > 1 and text[1] == '/') 2 else 1;
        const end = std.mem.indexOfAnyPos(u8, text, start, " \t\r\n/>") orelse return error.MalformedTheme;
        const close = std.mem.indexOfScalarPos(u8, text, end, '>') orelse return error.MalformedTheme;
        self.at += close + 1;
        return .{ .name = text[start..end], .empty = text[close - 1] == '/' };
    }

    /// Consume `</name>` when that is what comes next, and say whether it did.
    fn atClose(self: *Reader, name: []const u8) ReadError!bool {
        self.skipPadding();
        if (!std.mem.startsWith(u8, self.rest(), "</")) return false;
        const tag = try self.nextTag();
        if (!std.mem.eql(u8, tag.name, name)) return error.MalformedTheme;
        return true;
    }

    /// Consume `<name>...</name>` and return the text between them.
    fn expectText(self: *Reader, name: []const u8, scratch: std.mem.Allocator) ReadError![]const u8 {
        self.skipPadding();
        const tag = try self.nextTag();
        if (tag.empty or !std.mem.eql(u8, tag.name, name)) return error.MalformedTheme;
        return self.readText(name, scratch);
    }

    /// The text up to `</name>`, with the opening tag already consumed. A raw
    /// `<` cannot appear in plist text, so the first close tag after the cursor
    /// ends it - and if it names something else, the document is not the shape
    /// this reader was built for.
    fn readText(self: *Reader, name: []const u8, scratch: std.mem.Allocator) ReadError![]const u8 {
        const text = self.rest();
        const open = std.mem.indexOf(u8, text, "</") orelse return error.MalformedTheme;
        const after = open + 2;
        const end = std.mem.indexOfAnyPos(u8, text, after, " \t\r\n>") orelse return error.MalformedTheme;
        if (!std.mem.eql(u8, text[after..end], name)) return error.MalformedTheme;
        const close = std.mem.indexOfScalarPos(u8, text, end, '>') orelse return error.MalformedTheme;
        self.at += close + 1;
        return decodeEntities(scratch, text[0..open]);
    }

    /// Read one value. `depth` bounds the nesting, so a document cannot be a
    /// long chain of tags that only runs out of input at the end.
    fn parseValue(self: *Reader, scratch: std.mem.Allocator, depth: usize) ReadError!Value {
        if (depth > max_depth) return error.MalformedTheme;
        self.skipPadding();
        const tag = try self.nextTag();
        if (std.mem.eql(u8, tag.name, "dict")) {
            if (tag.empty) return error.MalformedTheme;
            return .{ .dict = try self.parseDict(scratch, depth) };
        }
        if (std.mem.eql(u8, tag.name, "array")) {
            if (tag.empty) return error.MalformedTheme;
            return .{ .array = try self.parseArray(scratch, depth) };
        }
        // `string` and `key` hold text; the scalars a plist may carry are
        // consumed and ignored, since nothing read here is one of them.
        for ([_][]const u8{ "string", "key", "integer", "real", "date", "data", "true", "false" }) |scalar| {
            if (!std.mem.eql(u8, tag.name, scalar)) continue;
            const holds_text = std.mem.eql(u8, scalar, "string") or std.mem.eql(u8, scalar, "key");
            if (tag.empty) return if (holds_text) Value{ .string = "" } else .other;
            const text = try self.readText(scalar, scratch);
            return if (holds_text) Value{ .string = text } else .other;
        }
        return error.MalformedTheme;
    }

    fn parseDict(self: *Reader, scratch: std.mem.Allocator, depth: usize) ReadError![]Entry {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(scratch);
        while (true) {
            if (try self.atClose("dict")) return entries.toOwnedSlice(scratch);
            const key = try self.expectText("key", scratch);
            try entries.append(scratch, .{ .key = key, .value = try self.parseValue(scratch, depth + 1) });
        }
    }

    fn parseArray(self: *Reader, scratch: std.mem.Allocator, depth: usize) ReadError![]Value {
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(scratch);
        while (true) {
            if (try self.atClose("array")) return items.toOwnedSlice(scratch);
            try items.append(scratch, try self.parseValue(scratch, depth + 1));
        }
    }
};

/// The nesting a theme document uses: plist, dict, array, dict, dict.
const max_depth = 8;

const testing = std.testing;

/// The colour a `#rrggbb` literal becomes, written out here rather than asked
/// of the importer, so the assertion does not read its own conversion back.
fn hex(value: u24, alpha: u8) theme.Color {
    return .{
        @as(f32, @floatFromInt((value >> 16) & 255)) / 255,
        @as(f32, @floatFromInt((value >> 8) & 255)) / 255,
        @as(f32, @floatFromInt(value & 255)) / 255,
        @as(f32, @floatFromInt(alpha)) / 255,
    };
}

/// The fixture, read the way the gate reads it: `zig build test` starts the
/// test binary in the repository root, which is where `tests/fixtures` sits.
/// A missing file is an error, not a skip - the fixture is part of the test.
fn fixture(a: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/monokai.tmTheme", a, .limited(theme.max_document_bytes));
}

test "the monokai fixture becomes a theme" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = try fixture(a);
    defer a.free(bytes);

    const monokai = try parse(a, bytes);
    try testing.expectEqualStrings("Monokai", monokai.name);

    // The entry with no scope is the editor's own background and foreground,
    // and those two are the whole of the chrome a tmTheme carries: every other
    // role keeps the colour the editor shipped with.
    var chrome = theme.defaults().chrome;
    chrome.background = hex(0x272822, 255);
    chrome.text = hex(0xF8F8F2, 255);
    try testing.expectEqual(chrome, monokai.chrome);

    // A tmTheme has no terminal palette, so the sixteen ANSI colours are not
    // read from it and the terminal keeps the defaults.
    try testing.expectEqual(theme.defaults().terminal, monokai.terminal);

    // Rules keep the file's order, which is what makes a later rule override an
    // earlier one.
    try testing.expectEqual(@as(usize, 4), monokai.syntax.len);
    try testing.expectEqualStrings("comment", monokai.syntax[0].selector);
    try testing.expectEqualStrings("string", monokai.syntax[1].selector);
    try testing.expectEqualStrings("keyword.control", monokai.syntax[2].selector);
    try testing.expectEqualStrings("constant.numeric", monokai.syntax[3].selector);

    const comment = theme.styleFor(monokai, "comment");
    try testing.expectEqual(hex(0x75715E, 255), comment.fg.?);
    try testing.expect(comment.italic);
    try testing.expect(!comment.bold);

    const string = theme.styleFor(monokai, "string");
    try testing.expectEqual(hex(0xE6DB74, 255), string.fg.?);

    const keyword = theme.styleFor(monokai, "keyword.control");
    try testing.expectEqual(hex(0xF92672, 255), keyword.fg.?);

    const number = theme.styleFor(monokai, "constant.numeric");
    try testing.expectEqual(hex(0xAE81FF, 255), number.fg.?);
}

test "a malformed tmTheme is an error, not a crash" {
    // No arena here on purpose: an error path has to free what it allocated,
    // and the testing allocator reports it when one does not.
    const a = testing.allocator;

    // The string is closed by a dict's tag, so the document is not a plist.
    try testing.expectError(error.MalformedTheme, parse(a, "<plist><dict><key>name</key><string>Broken</dict></plist>"));
    try testing.expectError(error.MalformedTheme, parse(a, "<plist><dict><key>settings</key><array>"));

    // A colour is `#rgb`, `#rrggbb`, or `#rrggbbaa`, and nothing else. The
    // first rule is imported before the second one is rejected, so this also
    // fails if the rules already built are not freed on the way out.
    try testing.expectError(error.InvalidColor, parse(a,
        \\<plist version="1.0"><dict><key>settings</key><array>
        \\<dict><key>scope</key><string>comment</string><key>settings</key><dict><key>foreground</key><string>#75715E</string></dict></dict>
        \\<dict><key>scope</key><string>string</string><key>settings</key><dict><key>foreground</key><string>purple</string></dict></dict>
        \\</array></dict></plist>
    ));
}

test "the short and eight-digit colour forms import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const loaded = try parse(a,
        \\<plist><dict><key>settings</key><array>
        \\<dict><key>scope</key><string>keyword</string><key>settings</key><dict><key>foreground</key><string>#f0a</string><key>background</key><string>#00000080</string></dict></dict>
        \\</array></dict></plist>
    );
    const keyword = theme.styleFor(loaded, "keyword");
    // `#f0a` is `#ff00aa`, and a scoped background reaches the rule as well as
    // a foreground does.
    try testing.expectEqual(hex(0xFF00AA, 255), keyword.fg.?);
    try testing.expectEqual(hex(0x000000, 0x80), keyword.bg.?);
}

test "oversized documents and rule lists are refused" {
    const a = testing.allocator;

    const oversized = try a.alloc(u8, theme.max_document_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try testing.expectError(error.ThemeTooLarge, parse(a, oversized));

    var document: std.ArrayList(u8) = .empty;
    defer document.deinit(a);
    try document.appendSlice(a, "<plist><dict><key>settings</key><array>");
    const rule = "<dict><key>scope</key><string>comment</string><key>settings</key><dict><key>foreground</key><string>#75715E</string></dict></dict>";
    for (0..theme.max_rules) |_| try document.appendSlice(a, rule);
    const closing = "</array></dict></plist>";
    try document.appendSlice(a, closing);

    // The ceiling itself is a document that is merely large, and what comes
    // back is a theme the caller can hand to `deinit` - which is what this
    // allocator checks when the test ends.
    const loaded = try parse(a, document.items);
    try testing.expectEqual(theme.max_rules, loaded.syntax.len);
    theme.deinit(loaded, a);

    document.items.len -= closing.len;
    try document.appendSlice(a, rule);
    try document.appendSlice(a, closing);
    try testing.expectError(error.TooManyRules, parse(a, document.items));
}
