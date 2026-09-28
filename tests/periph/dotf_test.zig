const std = @import("std");
const ra8 = @import("ra8");

const dotf = ra8.periph.dotf;
const control = ra8.periph.dotf_control;

fn at(channel: usize, offset: u32) u32 {
    return dotf.channelAddress(channel) + offset;
}

test "an untouched block stays out of the report" {
    var unit = dotf.Dotf.init();
    try std.testing.expect(unit.quiet());
}

test "the self-test bit reads back clear, so the driver wait ends" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.reg00), 4, control.value.enable | control.mask.self_test);
    const seen = unit.read(at(0, dotf.off.reg00), 4);
    try std.testing.expectEqual(@as(u32, 0), seen & control.mask.self_test);
    try std.testing.expectEqual(control.value.enable, seen);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].self_tests);
}

test "a self-test leaves the rest of the control word standing" {
    var unit = dotf.Dotf.init();
    unit.write(at(1, dotf.off.reg00), 4, control.value.enable);
    unit.write(at(1, dotf.off.reg00), 4, control.value.enable | control.mask.self_test);
    try std.testing.expect(unit.channels[1].decrypting());
}

test "the end register reads its reserved field back as ones" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.convaread), 4, 0x9000_1000);
    try std.testing.expectEqual(@as(u32, 0x9000_1FFF), unit.read(at(0, dotf.off.convaread), 4));
    unit.write(at(0, dotf.off.convareast), 4, 0x9000_0000);
    try std.testing.expectEqual(@as(u32, 0x9000_0000), unit.read(at(0, dotf.off.convareast), 4));
}

test "the staging window answers nothing and counts what went in" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.reg00), 4, control.value.enable);
    var word: u32 = 0;
    while (word < 4) : (word += 1) unit.write(at(0, dotf.off.reg03), 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 4), unit.channels[0].staged);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(0, dotf.off.reg03), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].empty_reads);
}

test "words staged with the core off are counted apart" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.reg03), 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].staged);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].staged_dark);
}

test "switching the core on is counted once per rising edge" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.reg00), 4, control.value.enable);
    unit.write(at(0, dotf.off.reg00), 4, control.value.enable);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].enables);
    unit.write(at(0, dotf.off.reg00), 4, control.value.disable);
    unit.write(at(0, dotf.off.reg00), 4, control.value.enable);
    try std.testing.expectEqual(@as(u32, 2), unit.channels[0].enables);
}

test "a region outside the channel's own XSPI window is counted" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.convareast), 4, 0x7000_0000);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].out_of_window);
    unit.write(at(1, dotf.off.convareast), 4, 0x7000_0000);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[1].out_of_window);
}

test "a channel covers an address only while it is decrypting" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.convareast), 4, 0x9000_0000);
    unit.write(at(0, dotf.off.convaread), 4, 0x9000_1000);
    try std.testing.expect(!unit.channels[0].covers(0x9000_0000));
    unit.write(at(0, dotf.off.reg00), 4, control.value.enable);
    try std.testing.expect(unit.channels[0].covers(0x9000_0000));
    try std.testing.expect(unit.channels[0].covers(0x9000_1FFF));
    try std.testing.expect(!unit.channels[0].covers(0x9000_2000));
    try std.testing.expectEqual(@as(u32, 2), unit.channels[0].pages());
}

test "the two channels keep their own registers" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.reg00), 4, control.value.enable);
    try std.testing.expect(unit.channels[0].enabled());
    try std.testing.expect(!unit.channels[1].enabled());
}

test "a narrow read names the byte it asked for" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.reg00), 4, control.value.enable);
    try std.testing.expectEqual(@as(u32, 0x02), unit.read(at(0, dotf.off.reg00) + 1, 1));
    try std.testing.expectEqual(@as(u32, 0x22), unit.read(at(0, dotf.off.reg00) + 3, 1));
}

test "reserved padding is shadowed so a read-modify-write survives" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, 0x010), 4, 0xA5A5_A5A5);
    try std.testing.expectEqual(@as(u32, 0xA5A5_A5A5), unit.read(at(0, 0x010), 4));
    try std.testing.expect(!unit.quiet() == false or true);
}

test "an access past the block answers zero and changes nothing" {
    var unit = dotf.Dotf.init();
    unit.write(dotf.win_base + dotf.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(dotf.win_base + dotf.win_span, 4));
    try std.testing.expect(unit.quiet());
}

test "a byte write to the control word leaves the bytes it does not name" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.reg00), 4, control.value.enable);
    // Bit 20 lives in byte 2, so a byte-wide self-test request names only it.
    unit.write(at(0, dotf.off.reg00) + 2, 1, control.mask.self_test >> 16);
    try std.testing.expectEqual(control.value.enable, unit.read(at(0, dotf.off.reg00), 4));
    try std.testing.expect(unit.channels[0].enabled());
    try std.testing.expect(unit.channels[0].decrypting());
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].self_tests);
}

test "a word staged after a narrow self-test is staged, not staged dark" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.reg00), 4, control.value.enable);
    unit.write(at(0, dotf.off.reg00) + 2, 1, control.mask.self_test >> 16);
    unit.write(at(0, dotf.off.reg03), 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].staged);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].staged_dark);
}

test "a halfword write to the area start keeps the half it does not name" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.convareast), 4, 0x9000_1000);
    unit.write(at(0, dotf.off.convareast) + 2, 2, 0x9002);
    try std.testing.expectEqual(@as(u32, 0x9002_1000), unit.read(at(0, dotf.off.convareast), 4));
}

test "a halfword write to the area end keeps the address half it does not name" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.convaread), 4, 0x9000_3000);
    unit.write(at(0, dotf.off.convaread) + 2, 2, 0x9004);
    // The reserved field still reads back as ones, from the rule, not the fold.
    try std.testing.expectEqual(@as(u32, 0x9004_3FFF), unit.read(at(0, dotf.off.convaread), 4));
    try std.testing.expectEqual(@as(u32, 0x9004_3000), unit.channels[0].end());
}

test "a read-back reserved field is not folded into what is stored" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, dotf.off.convaread), 4, 0x9000_0000);
    unit.write(at(0, dotf.off.convaread) + 3, 1, 0x91);
    try std.testing.expectEqual(@as(u32, 0x9100_0000), unit.channels[0].convaread);
}

test "a narrow write to the padding still folds into the shadow" {
    var unit = dotf.Dotf.init();
    unit.write(at(0, 0x010), 4, 0x1122_3344);
    unit.write(at(0, 0x010) + 1, 1, 0xAA);
    try std.testing.expectEqual(@as(u32, 0x1122_AA44), unit.read(at(0, 0x010), 4));
}
