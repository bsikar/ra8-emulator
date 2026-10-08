//! Tests for src/interfaces/rpc/session_periph.zig and
//! src/board/session_periph.zig (RA8EMU-818) on a real harness: periph
//! lists the blocks on cpu0's bus and the registers of one block, as text
//! and as JSON, and refuses what it cannot answer.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.interfaces.rpc.server;
const periph = ra8.interfaces.rpc.periph;
const board_periph = ra8.board.session_periph;
const app_codes = server.app_codes;

const image = "tests/fixtures/fpu/fp_basic.elf";

fn ask(context: *server.Context, block: []const u8, json: bool) ![]const u8 {
    return switch (periph.periph(context, .{ .core = .cpu0, .json = @intFromBool(json), .block = block })) {
        .ok => |listed| listed.text,
        .err => |code| if (@backingInt(code) == app_codes.too_long) error.TooLong else error.Refused,
    };
}

fn hooked(opened: anytype, scratch: []u8) server.Context {
    var context: server.Context = .{ .session = opened.session(), .scratch = scratch };
    context.peripherals = .{ .context = opened.board(), .listFn = board_periph.listBoard };
    return context;
}

test "cpu0's bus lists its blocks, RTC among them, one per line" {
    var opened = try ra8.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [16 * 1024]u8 = undefined;
    var context = hooked(&opened, &scratch);
    const text = try ask(&context, "", false);
    try std.testing.expect(std.mem.indexOf(u8, text, "RTC 0x40202000 0x80\n") != null);
    try std.testing.expectEqual(opened.board().bus.count, std.mem.count(u8, text, "\n"));
}

test "RTC's registers come back with their offsets and widths" {
    var opened = try ra8.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [4096]u8 = undefined;
    var context = hooked(&opened, &scratch);
    const text = try ask(&context, "RTC", false);
    try std.testing.expect(std.mem.startsWith(u8, text, "r64cnt 0x00 1\nseccnt 0x02 1\n"));
    try std.testing.expect(std.mem.endsWith(u8, text, "rcr4 0x28 1\n"));
    try std.testing.expectError(error.Refused, ask(&context, "nosuch", false));
}

test "the JSON forms parse, with an undeclared width as null" {
    var opened = try ra8.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [16 * 1024]u8 = undefined;
    var context = hooked(&opened, &scratch);
    const blocks = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, try ask(&context, "", true), .{});
    defer blocks.deinit();
    try std.testing.expectEqual(opened.board().bus.count, blocks.value.array.items.len);
    const rtc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, try ask(&context, "RTC", true), .{});
    defer rtc.deinit();
    const second = rtc.value.object.get("registers").?.array.items[1].object;
    try std.testing.expectEqualStrings("seccnt", second.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), second.get("offset").?.integer);
    try std.testing.expectEqual(@as(i64, 1), second.get("width").?.integer);
    const iwdt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, try ask(&context, "IWDT", true), .{});
    defer iwdt.deinit();
    try std.testing.expect(iwdt.value.object.get("registers").?.array.items[0].object.get("width").? == .null);
}

test "no hook refuses; a listing past the scratch is too long" {
    var opened = try ra8.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [16]u8 = undefined;
    var bare: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    try std.testing.expectError(error.Refused, ask(&bare, "", false));
    var context = hooked(&opened, &scratch);
    try std.testing.expectError(error.TooLong, ask(&context, "", false));
}
