const std = @import("std");
const theme = @import("../ui/theme.zig");
const text = @import("../core/text.zig");

/// Lexical language for token classification. Not a parser or language server.
pub const Language = enum {
    zig,
    c,
    python,
    javascript,
    plain,

    /// Choose a language from a file path extension, or `.plain` when unknown.
    pub fn detect(path: []const u8) Language {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".zig")) return .zig;
        if (std.ascii.eqlIgnoreCase(ext, ".c") or
            std.ascii.eqlIgnoreCase(ext, ".h") or
            std.ascii.eqlIgnoreCase(ext, ".cc") or
            std.ascii.eqlIgnoreCase(ext, ".cpp") or
            std.ascii.eqlIgnoreCase(ext, ".cxx") or
            std.ascii.eqlIgnoreCase(ext, ".hpp"))
            return .c;
        if (std.ascii.eqlIgnoreCase(ext, ".py") or std.ascii.eqlIgnoreCase(ext, ".pyw")) return .python;
        if (std.ascii.eqlIgnoreCase(ext, ".js") or
            std.ascii.eqlIgnoreCase(ext, ".mjs") or
            std.ascii.eqlIgnoreCase(ext, ".cjs") or
            std.ascii.eqlIgnoreCase(ext, ".jsx") or
            std.ascii.eqlIgnoreCase(ext, ".ts") or
            std.ascii.eqlIgnoreCase(ext, ".tsx"))
            return .javascript;
        return .plain;
    }

    fn keywords(self: Language) []const []const u8 {
        return switch (self) {
            .zig => &zig_keywords,
            .c => &c_keywords,
            .python => &python_keywords,
            .javascript => &javascript_keywords,
            .plain => &.{},
        };
    }
};

const zig_keywords = [_][]const u8{ "const", "var", "pub", "fn", "return", "try", "defer", "errdefer", "if", "else", "for", "while", "struct", "enum", "union", "error", "switch", "orelse", "catch", "comptime", "export", "extern", "test", "null", "undefined", "true", "false", "and", "or", "async", "await", "resume", "suspend", "threadlocal", "volatile", "addrspace", "callconv", "anytype", "anyframe", "inline", "noalias", "linksection", "usingnamespace", "allowzero", "unreachable" };
const python_keywords = [_][]const u8{ "def", "class", "return", "if", "elif", "else", "for", "while", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "pass", "break", "continue", "global", "nonlocal", "yield", "assert", "del", "in", "is", "not", "and", "or", "None", "True", "False", "async", "await", "match", "case" };
const c_keywords = [_][]const u8{ "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "struct", "union", "enum", "typedef", "static", "const", "volatile", "extern", "sizeof", "goto", "auto", "register", "inline", "class", "public", "private", "protected", "namespace", "template", "typename", "new", "delete", "this", "virtual", "override", "friend", "using", "try", "catch", "throw", "nullptr", "true", "false", "operator", "explicit", "constexpr", "noexcept" };
const javascript_keywords = [_][]const u8{ "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "new", "class", "extends", "super", "this", "import", "export", "from", "default", "try", "catch", "finally", "throw", "async", "await", "typeof", "instanceof", "in", "of", "null", "undefined", "true", "false", "static", "get", "set", "yield", "interface", "type", "enum", "implements", "private", "public", "protected", "readonly", "delete", "void" };

pub const Scanner = struct {
    language: Language = .plain,
    quote: u8 = 0,
    escaped: bool = false,
    comment: bool = false,
    block_comment: bool = false,
    skip: bool = false,

    pub fn color(self: *Scanner, bytes: []const u8, at: usize) theme.Color {
        const byte = bytes[at];
        if (self.skip) {
            self.skip = false;
            return theme.muted;
        }
        if (self.block_comment) {
            if (byte == '*' and at + 1 < bytes.len and bytes[at + 1] == '/') {
                self.block_comment = false;
                self.skip = true;
            }
            return theme.muted;
        }
        if (self.comment) return theme.muted;
        if (self.quote != 0) {
            if (self.escaped) {
                self.escaped = false;
            } else if (byte == '\\') {
                self.escaped = true;
            } else if (byte == self.quote) self.quote = 0;
            return theme.accent;
        }
        if (at + 1 < bytes.len and byte == '/' and bytes[at + 1] == '/') {
            self.comment = true;
            return theme.muted;
        }
        if (at + 1 < bytes.len and byte == '/' and bytes[at + 1] == '*') {
            self.block_comment = true;
            return theme.muted;
        }
        if (byte == '"' or byte == '\'') {
            self.quote = byte;
            return theme.accent;
        }
        if (byte >= '0' and byte <= '9') return theme.amber;
        if (byte == '@') return theme.purple;
        if (std.ascii.isAlphabetic(byte) or byte == '_') {
            var start = at;
            while (start > 0 and (std.ascii.isAlphanumeric(bytes[start - 1]) or bytes[start - 1] == '_')) : (start -= 1) {}
            var end = at;
            while (end < bytes.len and (std.ascii.isAlphanumeric(bytes[end]) or bytes[end] == '_')) : (end += 1) {}
            for (self.language.keywords()) |keyword| {
                if (std.mem.eql(u8, bytes[start..end], keyword)) return theme.purple;
            }
        }
        return theme.text;
    }

    /// Reset line-local state; block comments carry across lines.
    pub fn endLine(self: *Scanner) void {
        self.comment = false;
        self.quote = 0;
        self.escaped = false;
    }

    /// Process a whole line to carry state, without producing colors.
    pub fn scanLine(self: *Scanner, line: []const u8) void {
        var pos: usize = 0;
        while (pos < line.len) {
            _ = self.color(line, pos);
            pos = text.next(line, pos);
        }
        self.endLine();
    }
};

test "language detection by extension" {
    try std.testing.expectEqual(Language.zig, Language.detect("main.zig"));
    try std.testing.expectEqual(Language.c, Language.detect("app.cpp"));
    try std.testing.expectEqual(Language.python, Language.detect("script.py"));
    try std.testing.expectEqual(Language.javascript, Language.detect("index.ts"));
    try std.testing.expectEqual(Language.plain, Language.detect("README.md"));
}

test "keywords are language-specific" {
    var py = Scanner{ .language = .python };
    try std.testing.expectEqual(theme.purple, py.color("def x", 0));
    var zig = Scanner{ .language = .zig };
    try std.testing.expectEqual(theme.text, zig.color("def x", 0));
    var zz = Scanner{ .language = .zig };
    try std.testing.expectEqual(theme.purple, zz.color("comptime", 0));
    var plain = Scanner{ .language = .plain };
    try std.testing.expectEqual(theme.text, plain.color("const x", 0));
}

test "block comments span lines" {
    var scan = Scanner{ .language = .c };
    scan.scanLine("code /* comment");
    try std.testing.expectEqual(theme.muted, scan.color("still", 0));
    scan.scanLine("more */ code");
    try std.testing.expectEqual(theme.text, scan.color("code", 0));
}
