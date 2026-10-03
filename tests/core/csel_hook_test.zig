//! Covers src/core/csel_hook.zig.
//!
//! The decoder is covered on its own in tests/core/csel_test.zig. What is
//! worth checking here is the half that needs a live core: that Unicorn
//! really does hand the hook an encoding it cannot decode, that the result
//! lands in the register the encoding names, and that the run carries on
//! from the instruction after it.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const csel = ra8.core.csel;
const lob = ra8.core.lob;

const base: u32 = 0x2200_0000;

/// cmp r0, #0 / cset r1, eq / bkpt.
/// Assembled by arm-none-eabi-as 13.3.rel1 for armv8.1-m.main.
const compare_and_set = [_]u8{
    0x00, 0x28, //             2800       cmp r0, #0
    0x5F, 0xEA, 0x0F, 0x91, // ea5f 910f  cset r1, ne
    0x00, 0xBE, //             be00       bkpt
};

/// cmp r0, r1 / csel r2, r0, r1, eq / bkpt.
///
/// The compare is not decoration. A core out of reset here comes up with Z
/// already set, so a select written on its own would read as taken and the
/// test would pass for the wrong reason; the flags have to be put there by
/// the program that reads them.
const select_between = [_]u8{
    0x88, 0x42, //             4288       cmp r0, r1
    0x50, 0xEA, 0x01, 0x82, // ea50 8201  csel r2, r0, r1, eq
    0x00, 0xBE, //             be00       bkpt
};

test "a conditional select the CPU model cannot decode still produces a value" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    try core.write(base, &compare_and_set);

    var selects = csel.Selects{};
    try core.attachSelects(&selects);
    try core.setRegister(.r0, 0);
    try core.setRegister(.r1, 0xDEAD);

    const fault = try core.run(base, 16, .{});
    try std.testing.expect(fault != null);
    // r0 was zero, so eq held and cset r1, ne leaves zero behind.
    try std.testing.expectEqual(@as(u32, 0), try core.register(.r1));
    try std.testing.expectEqual(@as(usize, 1), selects.stepped);
    try std.testing.expect(!selects.quiet());
}

test "the same encoding gives one when the comparison fails" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    try core.write(base, &compare_and_set);

    var selects = csel.Selects{};
    try core.attachSelects(&selects);
    try core.setRegister(.r0, 7);

    _ = try core.run(base, 16, .{});
    try std.testing.expectEqual(@as(u32, 1), try core.register(.r1));
}

test "a three-register select reads both sources out of the core" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    try core.write(base, &select_between);

    var selects = csel.Selects{};
    try core.attachSelects(&selects);
    try core.setRegister(.r0, 0x1111);
    try core.setRegister(.r1, 0x2222);

    // The two differ, so eq fails and the else-source lands.
    _ = try core.run(base, 16, .{});
    try std.testing.expectEqual(@as(u32, 0x2222), try core.register(.r2));
    try std.testing.expectEqual(@as(usize, 1), selects.stepped);
}

test "the same select takes the then-source when the compare agrees" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    try core.write(base, &select_between);

    var selects = csel.Selects{};
    try core.attachSelects(&selects);
    try core.setRegister(.r0, 0x5555);
    try core.setRegister(.r1, 0x2222);
    try core.setRegister(.r2, 0);

    _ = try core.run(base, 16, .{});
    try std.testing.expectEqual(@as(u32, 0x2222), try core.register(.r2));

    try core.setRegister(.r1, 0x5555);
    _ = try core.run(base, 16, .{});
    try std.testing.expectEqual(@as(u32, 0x5555), try core.register(.r2));
    try std.testing.expectEqual(@as(usize, 2), selects.stepped);
}

test "the loop hook and the select hook do not get in each other's way" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    // dls lr, r0 / adds r1, #1 / le lr, back / cmp r0, #0 / cset r3, ne / bkpt.
    const both = [_]u8{
        0x40, 0xF0, 0x01, 0xE0, // dls lr, r0
        0x01, 0x31, //             adds r1, #1
        0x0F, 0xF0, 0x03, 0xC8, // le lr, -6
        0x00, 0x28, //             cmp r0, #0
        0x5F, 0xEA, 0x0F, 0x93, // cset r3, ne
        0x00, 0xBE, //             bkpt
    };
    try core.write(base, &both);

    var loops = lob.Loops{};
    var selects = csel.Selects{};
    try core.attachLoops(&loops);
    try core.attachSelects(&selects);
    try core.setRegister(.r0, 3);
    try core.setRegister(.r1, 0);

    _ = try core.run(base, 64, .{});
    try std.testing.expectEqual(@as(u32, 3), try core.register(.r1));
    // r0 is still 3, so ne holds and cset leaves one behind.
    try std.testing.expectEqual(@as(u32, 1), try core.register(.r3));
    // One DLS and three LE for the loop; one select. Neither hook claimed
    // the other's encoding.
    try std.testing.expectEqual(@as(usize, 4), loops.stepped);
    try std.testing.expectEqual(@as(usize, 1), selects.stepped);
}

test "an encoding no hook owns is still the fault it should be" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    // A genuinely undefined Thumb-2 word, claimed by neither decoder.
    try core.write(base, &[_]u8{ 0xFF, 0xF7, 0xFF, 0xFF });

    var selects = csel.Selects{};
    try core.attachSelects(&selects);

    const fault = try core.run(base, 16, .{});
    try std.testing.expect(fault != null);
    try std.testing.expectEqual(@as(usize, 0), selects.stepped);
}

test {
    _ = @import("clrm_test.zig");
}
