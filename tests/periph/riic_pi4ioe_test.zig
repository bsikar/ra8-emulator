//! The PI4IOE5V6408 expander: the register pointer and what it refuses.
const std = @import("std");
const ra8 = @import("ra8");
const pi4ioe = ra8.periph.riic_pi4ioe;

test "the device id reads its reset default" {
    var expander = pi4ioe.Expander{};
    expander.write(pi4ioe.file.device_id);
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), expander.read(buffer[0..]));
    try std.testing.expectEqual(pi4ioe.file.device_id_value, buffer[0]);
    try std.testing.expect(expander.quiet());
}

test "a write puts the pointer down first, then payload" {
    var expander = pi4ioe.Expander{};
    expander.write(0x05);
    expander.write(0xC3);
    try std.testing.expectEqual(@as(u8, 0xC3), expander.registers[0x05]);
    try std.testing.expectEqual(@as(u32, 1), expander.writes);
}

test "the pointer auto-increments through the payload" {
    var expander = pi4ioe.Expander{};
    expander.write(0x03);
    expander.write(0x11);
    expander.write(0x22);
    try std.testing.expectEqual(@as(u8, 0x11), expander.registers[0x03]);
    try std.testing.expectEqual(@as(u8, 0x22), expander.registers[0x04]);
    try std.testing.expectEqual(@as(u32, 2), expander.writes);
}

test "a register the part does not have is refused, not folded back in" {
    var expander = pi4ioe.Expander{};
    expander.write(0x25);
    try std.testing.expectEqual(@as(u32, 1), expander.bad_pointer);
    try std.testing.expect(!expander.pointed);
    // dev took 0x25 % 0x10 and wrote register 0x05 instead.
    expander.write(0xFF);
    try std.testing.expectEqual(@as(u8, 0), expander.registers[0x05]);
}

test "a payload byte with no pointer accepted lands nowhere" {
    var expander = pi4ioe.Expander{};
    expander.write(0x80);
    expander.write(0xAA);
    try std.testing.expectEqual(@as(u32, 0), expander.writes);
    for (expander.registers, 0..) |value, index| {
        if (index == pi4ioe.file.device_id) continue;
        try std.testing.expectEqual(@as(u8, 0), value);
    }
}

test "a read serves from the pointer and wraps inside the file" {
    var expander = pi4ioe.Expander{};
    expander.registers[0x0E] = 0xAA;
    expander.registers[0x0F] = 0xBB;
    expander.registers[0x00] = 0xCC;
    expander.write(0x0E);
    var buffer: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), expander.read(buffer[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, buffer[0..]);
}

test "a read never serves more than the file holds" {
    var expander = pi4ioe.Expander{};
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqual(pi4ioe.file.count, expander.read(buffer[0..]));
}

test "a stop ends the transfer so the next one names its own register" {
    var expander = pi4ioe.Expander{};
    expander.write(0x02);
    expander.write(0x77);
    expander.stop();
    expander.write(0x08);
    expander.write(0x99);
    try std.testing.expectEqual(@as(u8, 0x77), expander.registers[0x02]);
    try std.testing.expectEqual(@as(u8, 0x99), expander.registers[0x08]);
}
