//! JSON request access and response serialization.
const std = @import("std");
const framing = @import("framing.zig");
pub const Value = std.json.Value;

pub fn get(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
pub fn text(value: Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidArguments;
}
pub fn number(value: Value) !u32 {
    if (value != .integer) return error.InvalidArguments;
    return std.math.cast(u32, value.integer) orelse error.InvalidArguments;
}
pub fn list(value: Value) ![]Value {
    return if (value == .array) value.array.items else error.InvalidArguments;
}
pub fn quote(out: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, out);
}

pub fn response(allocator: std.mem.Allocator, out: *std.Io.Writer, seq: u32, request: Value, body: []const u8, failure: ?[]const u8) !void {
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    const w = &json.writer;
    try w.print("{{\"seq\":{d},\"type\":\"response\",\"request_seq\":{d},\"command\":", .{ seq, try number(get(request, "seq")) });
    try quote(w, try text(get(request, "command")));
    try w.print(",\"success\":{s}", .{if (failure == null) "true" else "false"});
    if (failure) |message| {
        try w.writeAll(",\"message\":");
        try quote(w, message);
    } else {
        try w.print(",\"body\":{s}", .{body});
    }
    try w.writeByte('}');
    try framing.write(out, json.written());
}

pub fn event(allocator: std.mem.Allocator, out: *std.Io.Writer, seq: u32, name: []const u8, body: anytype) !void {
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try quote(&json.writer, .{ .seq = seq, .type = "event", .event = name, .body = body });
    try framing.write(out, json.written());
}
