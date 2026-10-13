//! Board-side input queues and parser progress, not host stream handles.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;
const Reboot = @import("ra8_chip").core.reboot.Reboot;
pub const valid = @import("input_validation.zig").valid;
const script_skip = .{"events"};
const touch_skip = .{ "source", "switches", "line" };
const reply_skip = .{ "prompt", "text" };

pub fn save(board: anytype, writer: *std.Io.Writer) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(board, &counter.writer);
    try file.writeSectionHeader(writer, .board_inputs, counter.fullCount());
    try body(board, writer);
}

fn body(board: anytype, writer: *std.Io.Writer) !void {
    const script = &board.input_script;
    try fields.writeExcept(writer, script.*, script_skip);
    for (script.events[0..script.len]) |event| try fields.write(writer, event);
    try fields.writeExcept(writer, board.touch_input, touch_skip);
    try writer.writeAll(board.touch_input.line[0..board.touch_input.len]);
    try fields.writeExcept(writer, board.console_input.reply, reply_skip);
    const reboot: ?Reboot = if (board.reboot) |reboot| reboot.* else null;
    try fields.write(writer, reboot);
    try fields.write(writer, @as(u32, @intCast(board.usb.stick.disk.len)));
    try writer.writeAll(board.usb.stick.disk);
}

/// The caller owns a detached Board copy. Pointed-to reboot state is returned
/// separately so even this last section cannot mutate a live reset seam.
pub const Loaded = struct { reboot: ?Reboot, disk: []const u8 };

pub fn load(board: anytype, bytes: []const u8) !Loaded {
    const section = try file.Reader.find(bytes, .board_inputs) orelse return error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    try fields.readOver(&cursor, &board.input_script, script_skip);
    const script = &board.input_script;
    if (script.len > script.events.len or script.cursor > script.len) return error.BadValue;
    for (script.events[0..script.len]) |*event| event.* = try fields.read(@TypeOf(event.*), &cursor);
    if (!valid(script.*, board.time.base.now())) return error.BadValue;
    try fields.readOver(&cursor, &board.touch_input, touch_skip);
    const touch = &board.touch_input;
    if (touch.len > touch.line.len or touch.len > cursor.bytes.len - cursor.at) return error.BadValue;
    @memcpy(touch.line[0..touch.len], cursor.bytes[cursor.at..][0..touch.len]);
    cursor.at += touch.len;
    try fields.readOver(&cursor, &board.console_input.reply, reply_skip);
    const reboot = try fields.read(?Reboot, &cursor);
    const len = try fields.read(u32, &cursor);
    if (len != board.usb.stick.disk.len or len > cursor.bytes.len - cursor.at) return error.BadValue;
    const disk = cursor.bytes[cursor.at..][0..len];
    cursor.at += len;
    if (!cursor.done() or (reboot != null) != (board.reboot != null)) return error.BadValue;
    return .{ .reboot = reboot, .disk = disk };
}
