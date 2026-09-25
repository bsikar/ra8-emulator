//! Covers src/core/lob_hook.zig.
//!
//! The decoder is covered on its own in tests/core/lob_test.zig. What is
//! worth checking here is the half that needs a live core: that Unicorn
//! really does hand the hook an undecodable encoding, and really does resume
//! from the PC the hook leaves behind.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const lob = ra8.core.lob;

const base: u32 = 0x2200_0000;

/// dls lr, r0 / add r1, #1 / le lr, back to the add / bkpt.
/// Assembled by arm-none-eabi-as 13.3.rel1 for armv8.1-m.main.
const counted_loop = [_]u8{
    0x40, 0xF0, 0x01, 0xE0, // f040 e001  dls lr, r0
    0x01, 0x31, //             3101       adds r1, #1
    0x0F, 0xF0, 0x03, 0xC8, // f00f c803  le lr, -6
    0x00, 0xBE, //             be00       bkpt
};

test "a counted loop the CPU model cannot decode still runs its iterations" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    try core.write(base, &counted_loop);

    var loops = lob.Loops{};
    try core.attachLoops(&loops);
    try core.setRegister(.r0, 4);
    try core.setRegister(.r1, 0);

    const fault = try core.run(base, 64, .{});
    // The run ends on the bkpt past the loop, not inside it.
    try std.testing.expect(fault != null);
    try std.testing.expectEqual(@as(u32, 4), try core.register(.r1));
    try std.testing.expectEqual(@as(u32, 0), try core.register(.lr));
    // One DLS and four LE, the fourth of which empties the counter.
    try std.testing.expectEqual(@as(usize, 5), loops.stepped);
    try std.testing.expect(!loops.quiet());
}

test "a zero trip count skips the body entirely" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    // wls lr, r0, +10 / adds r1, #1 / adds r1, #1 / adds r1, #1 / bkpt
    try core.write(base, &[_]u8{
        0x40, 0xF0, 0x05, 0xC0, // f040 c005  wls lr, r0, +10
        0x01, 0x31, 0x01, 0x31,
        0x01, 0x31, 0x00, 0xBE,
    });

    var loops = lob.Loops{};
    try core.attachLoops(&loops);
    try core.setRegister(.r0, 0);
    try core.setRegister(.r1, 0);

    _ = try core.run(base, 64, .{});
    try std.testing.expectEqual(@as(u32, 0), try core.register(.r1));
    try std.testing.expectEqual(@as(usize, 1), loops.stepped);
}

test "a genuinely undefined encoding is still a fault" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.map(base, 0x1000);
    // An MVE vmov, which the hook refuses on purpose.
    try core.write(base, &[_]u8{ 0x4F, 0xEF, 0x58, 0x00 });

    var loops = lob.Loops{};
    try core.attachLoops(&loops);
    const fault = try core.run(base, 8, .{});
    try std.testing.expect(fault != null);
    try std.testing.expectEqual(@as(u32, base), fault.?.pc);
    try std.testing.expect(loops.quiet());
}
