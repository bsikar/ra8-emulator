//! Covers `src/chip/periph/irq_source.zig`: vendor-neutral `IrqSource` and
//! `DirectLines` delivery, level re-pending, acknowledgement, and line clamping.
const ra8 = @import("ra8");
const std = @import("std");

const irq_source = ra8.chip.periph.irq_source;
const memmap = ra8.chip.core.memmap;

const FakeNvic = struct {
    ispr: [16]u32 = @splat(0),

    pub fn readWord(self: *const FakeNvic, address: u32) !u32 {
        const idx = (address - memmap.nvic.ispr) / 4;
        return self.ispr[idx];
    }

    pub fn writeWord(self: *FakeNvic, address: u32, value: u32) !void {
        const idx = (address - memmap.nvic.ispr) / 4;
        self.ispr[idx] = value;
    }
};

test "DirectLines pends valid lines, drops out-of-range lines, and re-pends level sources" {
    var fake: FakeNvic = .{};
    var lines: irq_source.DirectLines = .{};
    lines.setLevelTriggered(36, true);
    const src = lines.irqSource();

    // Line 37 is outside a 37-line NVIC (0..36) and is dropped.
    try src.raise(&fake, 37, 37);
    try std.testing.expectEqual(@as(u64, 1), lines.dropped);
    try std.testing.expectEqual(@as(u32, 0), fake.ispr[1]);

    // Line 36 pends bit 4 of ISPR[1] and stays level-asserted until acknowledged.
    try src.raise(&fake, 37, 36);
    try std.testing.expect(src.asserted(36));
    try std.testing.expectEqual(@as(u32, 1 << 4), fake.ispr[1]);

    // Simulate NVIC entry clearing ISPR without acknowledging the peripheral latch.
    fake.ispr[1] = 0;
    try src.repend(&fake, 37);
    try std.testing.expectEqual(@as(u32, 1 << 4), fake.ispr[1]);
    try std.testing.expectEqual(@as(u64, 1), lines.repends);

    // Acknowledging clears the level latch so subsequent repend leaves ISPR clear.
    src.acknowledge(36);
    try std.testing.expect(!src.asserted(36));
    fake.ispr[1] = 0;
    try src.repend(&fake, 37);
    try std.testing.expectEqual(@as(u32, 0), fake.ispr[1]);

    // Reset clears any remaining latched lines.
    try src.raise(&fake, 37, 36);
    src.clearLatches();
    try std.testing.expect(!src.asserted(36));
}
