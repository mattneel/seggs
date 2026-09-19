const std = @import("std");
const theme = @import("../ui/theme.zig");

/// A line-local lexical baseline, not a parser or language server.
pub const Scanner = struct {
    quote: u8 = 0,
    escaped: bool = false,
    comment: bool = false,
    pub fn color(self: *Scanner, bytes: []const u8, at: usize) theme.Color {
        const byte = bytes[at];
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
            for ([_][]const u8{ "const", "var", "pub", "fn", "return", "try", "defer", "if", "else", "for", "while", "struct", "enum", "import", "export", "function", "let", "def", "do", "end" }) |keyword| {
                if (std.mem.eql(u8, bytes[start..end], keyword)) return theme.purple;
            }
        }
        return theme.text;
    }
};
