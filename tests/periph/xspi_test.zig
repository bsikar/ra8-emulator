//! Covers src/periph/xspi.zig: the manual-command engine, the write-enable
//! latch, and the descriptors it refuses.
const std = @import("std");
const ra8 = @import("ra8");

const xspi = ra8.periph.xspi;

fn cdt(opcode: u8, size: u32) u32 {
    // One opcode byte, left-justified in CMD: cmdsize 1, shift 8.
    return 1 | (size << xspi.descriptor.pos_datasize) |
        (@as(u32, opcode) << 24);
}

fn kick(unit: *xspi.Xspi, descriptor: u32, address: u32, data: [2]u32) void {
    unit.write(xspi.bufferAddress(xspi.slot.cdt), 4, descriptor);
    unit.write(xspi.bufferAddress(xspi.slot.address), 4, address);
    unit.write(xspi.bufferAddress(xspi.slot.data0), 4, data[0]);
    unit.write(xspi.bufferAddress(xspi.slot.data1), 4, data[1]);
    unit.write(xspi.win_base + xspi.off_cdctl0, 4, xspi.field.trreq);
}

fn word(unit: *xspi.Xspi, index: u32) u32 {
    return unit.read(xspi.bufferAddress(index), 4);
}

fn enable(unit: *xspi.Xspi) void {
    kick(unit, cdt(0x06, 0), 0, .{ 0, 0 });
}

test "the opcode comes out of the left-justified CMD field" {
    try std.testing.expectEqual(@as(u8, 0x9F), xspi.descriptor.opcode(cdt(0x9F, 0)));
    try std.testing.expectEqual(@as(u32, 4), xspi.descriptor.dataSize(cdt(0x03, 4)));
}

test "a kick raises CMDCMP, drops TRREQ, and INTC is the way back down" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    kick(&unit, cdt(0x9F, 3), 0, .{ 0, 0 });
    try std.testing.expectEqual(xspi.field.cmdcmp, unit.read(xspi.win_base + xspi.off_ints, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(xspi.win_base + xspi.off_cdctl0, 4) & xspi.field.trreq);

    unit.write(xspi.win_base + xspi.off_intc, 4, xspi.field.cmdcmp);
    try std.testing.expectEqual(@as(u32, 0), unit.read(xspi.win_base + xspi.off_ints, 4));
}

test "firmware cannot raise a completion itself" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(xspi.win_base + xspi.off_ints, 4, xspi.field.cmdcmp);
    try std.testing.expectEqual(@as(u32, 0), unit.read(xspi.win_base + xspi.off_ints, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.faked);
}

test "RDID answers with the JEDEC triplet" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    kick(&unit, cdt(0x9F, 3), 0, .{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 0x001A_5A9D), word(&unit, xspi.slot.data0));
}

test "RDSR reports the latch the model is holding" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    kick(&unit, cdt(0x05, 1), 0, .{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 0), word(&unit, xspi.slot.data0));

    enable(&unit);
    kick(&unit, cdt(0x05, 1), 0, .{ 0, 0 });
    try std.testing.expectEqual(xspi.status.wel, word(&unit, xspi.slot.data0));
}

test "a program without WREN changes nothing and is counted" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    kick(&unit, cdt(0x02, 4), 0x1000, .{ 0x0000_0000, 0 });
    try std.testing.expectEqual(@as(u32, 1), unit.unarmed);
    try std.testing.expectEqual(@as(u32, 0), unit.programs);
    try std.testing.expectEqual(@as(u8, 0xFF), unit.flash.byte(0x1000));
    // The command still completed: the engine is done with the descriptor.
    try std.testing.expectEqual(xspi.field.cmdcmp, unit.read(xspi.win_base + xspi.off_ints, 4));
}

test "an armed program lands and spends the latch" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    enable(&unit);
    kick(&unit, cdt(0x02, 4), 0x1000, .{ 0x0403_0201, 0 });
    try std.testing.expectEqual(@as(u32, 1), unit.programs);
    try std.testing.expectEqual(@as(u8, 0x01), unit.flash.byte(0x1000));
    try std.testing.expectEqual(@as(u8, 0x04), unit.flash.byte(0x1003));
    try std.testing.expect(!unit.write_enabled);

    // A second program on the spent latch is refused.
    kick(&unit, cdt(0x02, 1), 0x1004, .{ 0x0000_0055, 0 });
    try std.testing.expectEqual(@as(u32, 1), unit.unarmed);
    try std.testing.expectEqual(@as(u8, 0xFF), unit.flash.byte(0x1004));
}

test "a read serves the bytes the part is holding" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    enable(&unit);
    kick(&unit, cdt(0x02, 8), 0x2000, .{ 0x0403_0201, 0x0807_0605 });
    kick(&unit, cdt(0x03, 8), 0x2000, .{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 0x0403_0201), word(&unit, xspi.slot.data0));
    try std.testing.expectEqual(@as(u32, 0x0807_0605), word(&unit, xspi.slot.data1));
    try std.testing.expectEqual(@as(u32, 1), unit.reads);
}

test "a read of an untouched part gives erased bytes" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    kick(&unit, cdt(0x03, 8), 0x3000, .{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), word(&unit, xspi.slot.data0));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), word(&unit, xspi.slot.data1));
}

test "a program only clears bits, and only an erase gives them back" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    enable(&unit);
    kick(&unit, cdt(0x02, 1), 0x4000, .{ 0x0000_00F0, 0 });
    enable(&unit);
    kick(&unit, cdt(0x02, 1), 0x4000, .{ 0x0000_000F, 0 });
    try std.testing.expectEqual(@as(u8, 0x00), unit.flash.byte(0x4000));

    enable(&unit);
    kick(&unit, cdt(0x20, 0), 0x4FFF, .{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 1), unit.erases);
    try std.testing.expectEqual(@as(u8, 0xFF), unit.flash.byte(0x4000));
}

test "an erase without WREN leaves the sector alone" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    enable(&unit);
    kick(&unit, cdt(0x02, 1), 0x5000, .{ 0x0000_0000, 0 });
    kick(&unit, cdt(0x20, 0), 0x5000, .{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 0), unit.erases);
    try std.testing.expectEqual(@as(u32, 1), unit.unarmed);
    try std.testing.expectEqual(@as(u8, 0x00), unit.flash.byte(0x5000));
}

test "a descriptor asking for more than the slot holds is refused" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    enable(&unit);
    kick(&unit, cdt(0x02, 15), 0x6000, .{ 0x0000_0000, 0x0000_0000 });
    try std.testing.expectEqual(@as(u32, 1), unit.oversized);
    try std.testing.expectEqual(@as(u32, 0), unit.programs);
    try std.testing.expectEqual(@as(u8, 0xFF), unit.flash.byte(0x6000));

    kick(&unit, cdt(0x03, 9), 0x6000, .{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 2), unit.oversized);
    try std.testing.expectEqual(@as(u32, 0), unit.reads);
}

test "a command that runs off the end of the part is refused" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    enable(&unit);
    kick(&unit, cdt(0x02, 8), xspi.part.size - 4, .{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 1), unit.out_of_part);
    try std.testing.expectEqual(@as(u32, 0), unit.programs);

    kick(&unit, cdt(0x20, 0), xspi.part.size, .{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 2), unit.out_of_part);
}

test "an unknown opcode completes and touches nothing" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    enable(&unit);
    kick(&unit, cdt(0x66, 0), 0, .{ 0, 0 });
    try std.testing.expectEqual(xspi.field.cmdcmp, unit.read(xspi.win_base + xspi.off_ints, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.programs);
    // The reset opcodes do not spend the latch either.
    try std.testing.expect(unit.write_enabled);
}

test "a byte store keeps the bytes above it" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(xspi.win_base + xspi.off_cdctl0, 4, 0x5A5A_5A00);
    unit.write(xspi.win_base + xspi.off_cdctl0, 1, xspi.field.trreq);
    // TRREQ self-cleared, CSSEL and the bytes above it survived.
    try std.testing.expectEqual(@as(u32, 0x5A5A_5A00), unit.read(xspi.win_base + xspi.off_cdctl0, 4));
    try std.testing.expectEqual(xspi.field.cmdcmp, unit.read(xspi.win_base + xspi.off_ints, 4));
}

test "a store outside the window moves nothing" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(xspi.win_base + xspi.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(xspi.win_base + xspi.win_span, 4));
    try std.testing.expect(unit.quiet());
}

test "the block descriptor covers the window" {
    var unit = xspi.Xspi.init(std.testing.allocator);
    defer unit.deinit();

    const block = unit.block();
    try std.testing.expectEqual(xspi.win_base, block.base);
    try std.testing.expectEqual(xspi.win_span, block.size);
}
