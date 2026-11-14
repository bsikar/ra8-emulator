//! Firmware NVIC commands and the shared Secure/Non-secure state.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.core.cpu.board_bus.nvic_registers;
const ram = @import("exception/ram.zig");
const map = ra8.chip.core.memmap;
const offset = ra8.chip.periph.scs_alias.offset;

fn read(memory: *ram.Ram, address: u32, secure: bool) !u32 {
    var bytes: [4]u8 = undefined;
    try regs.read(memory.view(), address, secure, &bytes);
    return std.mem.readInt(u32, &bytes, .little);
}

fn write(memory: *ram.Ram, address: u32, secure: bool, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try regs.write(memory.view(), address, secure, &bytes);
}

test "all implemented words accumulate sets, ignore zeros and read clear aliases as state" {
    var memory: ram.Ram = .{};
    for ([_]u32{ map.nvic.iser, map.nvic.ispr }) |base| {
        for (0..3) |word| {
            const address = base + @as(u32, @intCast(word)) * 4;
            try write(&memory, address, true, 1);
            try write(&memory, address, true, 4);
            try write(&memory, address, true, 0);
            try std.testing.expectEqual(@as(u32, 5), try read(&memory, address + 0x80, true));
            try write(&memory, address + 0x80, true, 1);
            try write(&memory, address + 0x80, true, 0);
            try std.testing.expectEqual(@as(u32, 4), try read(&memory, address, true));
        }
    }
}

test "NS alias shares state and masks both set and clear commands by ITNS" {
    var memory: ram.Ram = .{};
    memory.putWord(0xE000_E380, 6); // lines 1 and 2 target Non-secure
    for ([_]u32{ map.nvic.iser, map.nvic.ispr }) |address| {
        try write(&memory, address, true, 1);
        try write(&memory, address + offset, true, 0xF);
        try std.testing.expectEqual(@as(u32, 7), try read(&memory, address, true));
        try std.testing.expectEqual(@as(u32, 6), try read(&memory, address + offset, true));
        try std.testing.expectEqual(@as(u32, 6), try read(&memory, address, false));
        try write(&memory, address + 0x80 + offset, true, 3);
        try std.testing.expectEqual(@as(u32, 5), try read(&memory, address, true));
        try write(&memory, address + 0x80, false, 5);
        try std.testing.expectEqual(@as(u32, 1), try read(&memory, address, true));
        try std.testing.expectEqual(@as(u32, 0), try read(&memory, address + offset, false));
        try write(&memory, address + offset, false, 6);
        try std.testing.expectEqual(@as(u32, 1), try read(&memory, address, true));
    }
}

test "unimplemented IRQ words are RES0 and narrow or unaligned commands are refused atomically" {
    var memory: ram.Ram = .{};
    for ([_]u32{ map.nvic.iser, map.nvic.icer, map.nvic.ispr, map.nvic.icpr }) |base| {
        try write(&memory, base + 12, true, 0xFFFF_FFFF);
        try std.testing.expectEqual(@as(u32, 0), try read(&memory, base + 12, true));
        var bytes = [_]u8{ 1, 2, 3, 4 };
        memory.putWord(base, 0xA5A5_A5A5);
        for ([_]usize{ 1, 2 }) |len| {
            try std.testing.expectError(error.Unmapped, regs.write(memory.view(), base, true, bytes[0..len]));
            try std.testing.expectError(error.Unmapped, regs.read(memory.view(), base, true, bytes[0..len]));
        }
        try std.testing.expectError(error.Unmapped, regs.write(memory.view(), base + 1, true, &bytes));
        try std.testing.expectError(error.Unmapped, regs.read(memory.view(), base + 1, true, &bytes));
        try std.testing.expectEqual(@as(u32, 0xA5A5_A5A5), memory.word(base));
    }
    try std.testing.expect(!regs.covers(map.nvic.iser - 1));
    try std.testing.expect(!regs.covers(map.nvic.ipr));
}
