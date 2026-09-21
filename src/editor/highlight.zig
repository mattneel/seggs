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

    /// The colour at a position, which is its role resolved through whatever
    /// theme is loaded.
    pub fn color(self: *Scanner, bytes: []const u8, at: usize) theme.Color {
        return resolve(self.roleAt(bytes, at));
    }

    /// What a position in the line is, in the vocabulary themes are written in.
    ///
    /// The scanner already decides this - it is the same state machine either
    /// way - but naming the decision is what lets a theme reach our syntax. A
    /// theme file describes `comment` and `string.quoted`; a scanner that
    /// answers with a colour directly can only ever be themed by rewriting it,
    /// which is why importing one would otherwise be decorative.
    pub const Role = enum {
        plain,
        comment,
        string,
        number,
        keyword,
        decorator,

        /// The TextMate selector this role answers to, which is the name every
        /// editor's theme files use for the same thing. Empty for plain text:
        /// it has no rule of its own, and what it gets is the editor's
        /// foreground.
        pub fn scope(self: Role) []const u8 {
            return switch (self) {
                .plain => "",
                .comment => "comment",
                .string => "string.quoted",
                .number => "constant.numeric",
                .keyword => "keyword.control",
                .decorator => "storage.type.annotation",
            };
        }
    };

    /// A loaded theme's rule for a role, and the palette's own role colour when
    /// the theme says nothing about it. A theme is a document written by
    /// someone else about a language we only partly understand, so a scope it
    /// never mentions must keep working rather than go blank.
    fn resolve(role: Role) theme.Color {
        const scope = role.scope();
        if (scope.len > 0) {
            if (theme.styleFor(theme.current, scope).fg) |fg| return fg;
        }
        return switch (role) {
            .plain => theme.text,
            .comment => theme.muted,
            .string => theme.accent,
            .number => theme.amber,
            .keyword, .decorator => theme.purple,
        };
    }

    /// The same decision as `color`, with no colour: the state machine lives
    /// here so that carrying state and drawing cannot disagree about it.
    pub fn roleAt(self: *Scanner, bytes: []const u8, at: usize) Role {
        const byte = bytes[at];
        if (self.skip) {
            self.skip = false;
            return .comment;
        }
        if (self.block_comment) {
            if (byte == '*' and at + 1 < bytes.len and bytes[at + 1] == '/') {
                self.block_comment = false;
                self.skip = true;
            }
            return .comment;
        }
        if (self.comment) return .comment;
        if (self.quote != 0) {
            if (self.escaped) {
                self.escaped = false;
            } else if (byte == '\\') {
                self.escaped = true;
            } else if (byte == self.quote) self.quote = 0;
            return .string;
        }
        if (at + 1 < bytes.len and byte == '/' and bytes[at + 1] == '/') {
            self.comment = true;
            return .comment;
        }
        if (at + 1 < bytes.len and byte == '/' and bytes[at + 1] == '*') {
            self.block_comment = true;
            return .comment;
        }
        if (byte == '"' or byte == '\'') {
            self.quote = byte;
            return .string;
        }
        if (byte >= '0' and byte <= '9') return .number;
        if (byte == '@') return .decorator;
        if (std.ascii.isAlphabetic(byte) or byte == '_') {
            var start = at;
            while (start > 0 and (std.ascii.isAlphanumeric(bytes[start - 1]) or bytes[start - 1] == '_')) : (start -= 1) {}
            var end = at;
            while (end < bytes.len and (std.ascii.isAlphanumeric(bytes[end]) or bytes[end] == '_')) : (end += 1) {}
            for (self.language.keywords()) |keyword| {
                if (std.mem.eql(u8, bytes[start..end], keyword)) return .keyword;
            }
        }
        return .plain;
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

test "a theme's scope rules reach the syntax they name" {
    const a = std.testing.allocator;
    // A theme that says what a comment and a keyword look like. This is the
    // whole point of importing one: the rules arrive in someone else's
    // vocabulary and have to land on our tokenizer.
    const document =
        \\{"name":"probe",
        \\ "syntax":[
        \\   {"scope":"comment","fg":"#ff0000"},
        \\   {"scope":"keyword.control","fg":"#00ff00"},
        \\   {"scope":"string.quoted","fg":"#0000ff"}]}
    ;
    const parsed = try theme.parse(a, document);
    defer theme.deinit(parsed, a);

    const previous = theme.current;
    const previous_palette = .{ theme.text, theme.muted, theme.accent, theme.purple };
    theme.apply(parsed);
    defer {
        theme.apply(previous);
        theme.text = previous_palette[0];
        theme.muted = previous_palette[1];
        theme.accent = previous_palette[2];
        theme.purple = previous_palette[3];
    }

    // A scanner carries state from one position to the next - that is how a
    // block comment or an open string spans a line - so each of these gets its
    // own rather than inheriting the last one's idea of what it was reading.
    const zero = struct {
        fn at(line: []const u8) theme.Color {
            var scanner: Scanner = .{ .language = .zig };
            return scanner.color(line, 0);
        }
    }.at;

    // Each line is a position whose role the scanner decides, and the colour
    // has to be the one the theme named for that role.
    try std.testing.expectEqual(theme.rgb(0xff0000), zero("// hi"));
    try std.testing.expectEqual(theme.rgb(0x0000ff), zero("\"quoted\""));
    try std.testing.expectEqual(theme.rgb(0x00ff00), zero("const x = 1;"));
    // A scope the theme says nothing about keeps the palette's own colour
    // rather than going blank: a document is a partial statement by nature.
    try std.testing.expectEqual(theme.amber, zero("42"));
}
