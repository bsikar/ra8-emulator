//! The debugger's rewind history over a real harness (RA8EMU-1170): a stop
//! recorded into the ring at every run and step, a rewind that puts the
//! core and the store back, a step that replays forward exactly, and a ring
//! that drops the oldest frame past its stated capacity.

const std = @import("std");
const ra8 = @import("ra8");

const elf_path = "tests/fixtures/dfu/dfu_bootloader.elf";

test "steps are recorded and a rewind puts the run back (RA8EMU-1170)" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = elf_path });
    defer opened.deinit();
    const session = opened.session();
    const history = opened.history();

    var pcs: [8]u32 = undefined;
    for (0..8) |i| {
        _ = try session.run(.cpu0, .step);
        pcs[i] = session.live.core.cpu.regs.pc;
    }
    try std.testing.expectEqual(@as(u32, 8), history.count);

    // Two stops back is the state the run showed then...
    try session.rewind(.cpu0, 2);
    try std.testing.expectEqual(pcs[5], session.live.core.cpu.regs.pc);

    // ...and one step forward replays exactly what followed it.
    _ = try session.run(.cpu0, .step);
    try std.testing.expectEqual(pcs[6], session.live.core.cpu.regs.pc);

    // A rewind past the recorded window refuses rather than guessing.
    try std.testing.expectError(ra8.session.api.History.Error.NotRecorded, history.frame(9));
}

test "the ring drops its oldest frame past the stated capacity (RA8EMU-1170)" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = elf_path,
        .history_frames = 4,
    });
    defer opened.deinit();
    const session = opened.session();
    const history = opened.history();

    var pcs: [6]u32 = undefined;
    for (0..6) |i| {
        _ = try session.run(.cpu0, .step);
        pcs[i] = session.live.core.cpu.regs.pc;
    }
    try std.testing.expectEqual(@as(u32, 4), history.count);

    // The first two stops fell off; the window holds the last four.
    try std.testing.expectEqual(pcs[5], (try history.frame(0)).pc);
    try std.testing.expectEqual(pcs[2], (try history.frame(3)).pc);
    try std.testing.expectError(ra8.session.api.History.Error.NotRecorded, history.frame(4));

    // Restoring the oldest live frame still lands its state exactly.
    try session.rewind(.cpu0, 3);
    try std.testing.expectEqual(pcs[2], session.live.core.cpu.regs.pc);
}
