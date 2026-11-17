//! Tests for src/session/disasm.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.session.disasm;

const Error = mod.Error;
const one = mod.one;

test "a Thumb store decodes to its mnemonic and operands" {
    const text = try one(0x2200_0000, &[_]u8{ 0x01, 0x60 });
    try std.testing.expectEqualStrings("str r1, [r0]", text.slice());
}

test "a 32-bit encoding reads both halfwords" {
    // ldr.w r1, [r0, #4]: hw1 0xF8D0, hw2 0x1004.
    const text = try one(0x2200_0000, &[_]u8{ 0xD0, 0xF8, 0x04, 0x10 });
    try std.testing.expectEqualStrings("ldr.w r1, [r0, #4]", text.slice());
}

test "a wide first halfword without its second is an error" {
    try std.testing.expectError(Error.NothingDecoded, one(0x2200_0000, &[_]u8{ 0xD0, 0xF8 }));
}

test "fewer than two bytes is an error" {
    try std.testing.expectError(Error.NothingDecoded, one(0x2200_0000, &[_]u8{0x01}));
}

const fixture = @import("annotation_fixture.zig");

test "fixture ELF names function target current function locals and constant byte for byte" {
    var bytes: [2048]u8 = undefined;
    const image = try fixture.image(&bytes);
    var ram = fixture.Ram.init();
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = ram.view() };
    var rows: [4]mod.Row = undefined;
    try std.testing.expectEqual(@as(u32, 0x10c), try mod.capture(.{ .zig = .{ .cpu = &cpu } }, image, 0x100, &rows));
    var output: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    for (rows) |row| try mod.write(row, &writer);
    try std.testing.expectEqualStrings(fixture.golden, writer.buffered());
}

test "raw decoding stays raw while bounded pane rows fail safely on unreadable bytes" {
    var ram = fixture.Ram.init();
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = ram.view() };
    const view: ra8.session.core_view.View = .{ .zig = .{ .cpu = &cpu } };
    var rows: [1]mod.Row = undefined;
    try std.testing.expectError(error.BadDisassemblyRange, mod.capture(view, null, 0x101, &rows));
    _ = try mod.capture(view, null, 0x200, &rows);
    try std.testing.expectEqualStrings("<unreadable>", rows[0].text.slice());
    const raw = try mod.one(0x102, ram.bytes[2..6]);
    try std.testing.expectEqualStrings("movw r2, #0x5fa", raw.slice());
}

test "literal loads name model registers from live ordinary memory without ELF debug data" {
    var ram = fixture.Ram.init();
    ram.base = 0x0200_0000;
    @memcpy(ram.bytes[0..8], &[_]u8{ 0, 0x48, 0, 0xbf, 0x0c, 0xed, 0, 0xe0 });
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = ram.view() };
    const row = mod.read(.{ .zig = .{ .cpu = &cpu } }, null, ram.base);
    try std.testing.expectEqualStrings("ldr r0, [pc, #0] ; =SCB.aircr", row.text.slice());
    std.mem.writeInt(u32, ram.bytes[4..8], 0x1234, .little);
    const changed = mod.read(.{ .zig = .{ .cpu = &cpu } }, null, ram.base);
    try std.testing.expectEqualStrings("ldr r0, [pc, #0]", changed.text.slice());
}
