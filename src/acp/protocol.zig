const std = @import("std");
pub const Value = std.json.Value;
pub const version: u32 = 1;

pub fn field(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}

pub fn string(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

pub fn str(value: Value, key: []const u8) []const u8 {
    return string(field(value, key) orelse return "") orelse "";
}

pub fn integer(value: Value) ?i64 {
    return if (value == .integer) value.integer else null;
}

pub const Kind = enum { request, notification, response };
pub fn classify(value: Value) !Kind {
    if (value != .object or !std.mem.eql(u8, str(value, "jsonrpc"), "2.0")) return error.InvalidEnvelope;
    const id = field(value, "id");
    if (id) |v| if (v != .integer and v != .string) return error.InvalidId;
    if (field(value, "method")) |method| {
        if (method != .string or field(value, "result") != null or field(value, "error") != null) return error.InvalidEnvelope;
        return if (id != null) .request else .notification;
    }
    if (id == null or ((field(value, "result") != null) == (field(value, "error") != null))) return error.InvalidEnvelope;
    return .response;
}

pub fn request(a: std.mem.Allocator, id: u64, method: []const u8, params: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, .{});
}

pub fn notification(a: std.mem.Allocator, method: []const u8, params: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = method, .params = params }, .{});
}

pub fn result(a: std.mem.Allocator, id: Value, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .result = value }, .{});
}

pub fn failure(a: std.mem.Allocator, id: Value, code: i32, message: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }, .{});
}

test "serialize escaped prompt and classify response" {
    const a = std.testing.allocator;
    const wire = try request(a, 7, "session/prompt", .{ .text = "quote: \"\n" });
    defer a.free(wire);
    const p = try std.json.parseFromSlice(Value, a, wire, .{});
    defer p.deinit();
    try std.testing.expectEqual(Kind.request, try classify(p.value));
    const reply = try std.json.parseFromSlice(Value, a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}", .{});
    defer reply.deinit();
    try std.testing.expectEqual(Kind.response, try classify(reply.value));
}

test "reject ambiguous response envelope" {
    const p = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{}}", .{});
    defer p.deinit();
    try std.testing.expectError(error.InvalidEnvelope, classify(p.value));
}
