//! Extension contracts only. No LSP, DAP, PTY, or Git service starts in this scaffold.
const std = @import("std");

pub const Position = struct { line: u32, utf16_character: u32 };
pub const Range = struct { start: Position, end: Position };
pub const Diagnostic = struct { range: Range, message: []const u8, severity: enum { hint, information, warning, failure } };

/// An edit must name the document revision that it expects.
pub const ProposedEdit = struct {
    path: []const u8,
    expected_revision: u64,
    start_byte: usize,
    end_byte: usize,
    replacement: []const u8,
};

pub const LanguageService = struct {
    context: *anyopaque,
    did_change: *const fn (*anyopaque, []const u8, u64, []const u8) anyerror!void,
    diagnostics: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]Diagnostic,
};

pub const DebugService = struct {
    context: *anyopaque,
    launch: *const fn (*anyopaque, []const u8) anyerror!void,
    pause: *const fn (*anyopaque) anyerror!void,
    stop: *const fn (*anyopaque) anyerror!void,
};
