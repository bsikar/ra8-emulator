//! Integration test for RA4T1 peripheral bus wiring and ROM seeding.
const ra8 = @import("ra8");
const std = @import("std");

const catalog = ra8.chip.core.machine.catalog;
const periph = ra8.chip.periph;
const ra4t1 = ra8.chip.vendor.renesas.ra4t1;

test "RA4T1 State attaches cleanly onto peripheral Bus and seeds ROM" {
    var store = try ra8.chip.core.cpu.memory.store.Store.initFor(null, catalog.ra4t1.memory);
    defer store.deinit();
    const guest = ra8.chip.core.cpu.memory.guest.Guest{ .store = &store };
    try ra4t1.seedRom(guest);

    var pnr: [16]u8 = undefined;
    try guest.read(0x0100_80F0, &pnr);
    try std.testing.expectEqualStrings("R7FA4T1BB3CFM   ", &pnr);

    var ofs1: [4]u8 = undefined;
    try guest.read(0x0100_A200, &ofs1);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0xFF }, &ofs1);

    var bus = periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    bus.windows = catalog.ra4t1.memory.mmio;
    bus.unknown = catalog.ra4t1.memory.unknown_mmio;

    var state: ra4t1.State = .{};
    try state.attachToBus(&bus);
    try std.testing.expectEqual(@as(u32, 0x2200_2222), bus.read(0x4001_E020, 4));
    try std.testing.expect(bus.tryRead(0x5011_8900, 1) == null);
    try std.testing.expect(bus.tryRead(0x4018_0000, 4) == null);
}
