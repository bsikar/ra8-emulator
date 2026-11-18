//! Covers `src/chip/periph/icu/source.zig`: `Icu` adapted to `IrqSource`.
const ra8 = @import("ra8");
const std = @import("std");

const icu = ra8.chip.periph.icu;
const memmap = ra8.chip.core.memmap;

const FakeNvic = struct {
    ispr: [16]u32 = @splat(0),

    pub fn readWord(self: *const FakeNvic, address: u32) !u32 {
        return self.ispr[(address - memmap.nvic.ispr) / 4];
    }

    pub fn writeWord(self: *FakeNvic, address: u32, value: u32) !void {
        self.ispr[(address - memmap.nvic.ispr) / 4] = value;
    }
};

test "ICU IrqSource routes linked events, clamps to irq_lines, and re-pends latched slots" {
    var unit = icu.Icu.init();
    unit.links[5] = 0x2A;
    unit.links[40] = 0x2B;
    var fake: FakeNvic = .{};
    const src = unit.irqSource();

    // With irq_lines = 32, slot 40 is clamped while slot 5 pends and latches IR.
    try src.raise(&fake, 32, 0x2B);
    try std.testing.expectEqual(@as(u32, 0), fake.ispr[1]);
    try src.raise(&fake, 32, 0x2A);
    try std.testing.expect(src.asserted(5));
    try std.testing.expectEqual(@as(u32, 1 << 5), fake.ispr[0]);

    fake.ispr[0] = 0;
    try src.repend(&fake, 32);
    try std.testing.expectEqual(@as(u32, 1 << 5), fake.ispr[0]);

    src.acknowledge(5);
    try std.testing.expect(!src.asserted(5));
}
