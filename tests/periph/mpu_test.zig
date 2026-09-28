//! The MPU window: the region count it reports, and the table it captures.
const std = @import("std");
const ra8 = @import("ra8");
const mpu = ra8.periph.mpu;
const memmap = ra8.core.memmap;

/// A stand-in for the core that holds the PPB words the block reads and writes.
const FakePpb = struct {
    words: std.AutoHashMap(u32, u32),

    fn init(allocator: std.mem.Allocator) FakePpb {
        return .{ .words = std.AutoHashMap(u32, u32).init(allocator) };
    }

    fn deinit(self: *FakePpb) void {
        self.words.deinit();
    }

    pub fn readWord(self: *FakePpb, address: u32) !u32 {
        return self.words.get(address) orelse 0;
    }

    pub fn writeWord(self: *FakePpb, address: u32, value: u32) !void {
        try self.words.put(address, value);
    }
};

test "TYPE reports the region count this core implements" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();

    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.mpu.type_));
    try unit.prime(&ppb);
    const value = try ppb.readWord(memmap.mpu.type_);
    try std.testing.expectEqual(mpu.geometry.type_value, value);
    try std.testing.expectEqual(
        @as(u32, mpu.geometry.regions),
        (value & 0x0000_FF00) >> mpu.geometry.dregion_shift,
    );
}

test "a store to TYPE is turned away and the count put back" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();
    try unit.prime(&ppb);

    try ppb.writeWord(memmap.mpu.type_, 0);
    try unit.poll(&ppb);

    try std.testing.expectEqual(@as(u32, 1), unit.refused);
    try std.testing.expectEqual(mpu.geometry.type_value, try ppb.readWord(memmap.mpu.type_));
}

test "a region is captured out of the RBAR and RLAR pair that programs it" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();
    try unit.prime(&ppb);

    // Region 1 covers 0x2200_0000..0x2200_1FFF, read-only and not executable.
    try ppb.writeWord(memmap.mpu.rnr, 1);
    try ppb.writeWord(memmap.mpu.rbar, 0x2200_0000 | mpu.field.rbar_ap_ro | mpu.field.rbar_xn);
    try ppb.writeWord(memmap.mpu.rlar, 0x2200_1FE0 | mpu.field.rlar_enable);
    try unit.poll(&ppb);

    const region = unit.table[1];
    try std.testing.expect(region.enabled);
    try std.testing.expect(region.read_only);
    try std.testing.expect(!region.executable);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), region.base);
    try std.testing.expectEqual(@as(u32, 0x2200_1FFF), region.limit);
    try std.testing.expectEqual(@as(u32, 0x2000), region.bytes());
    try std.testing.expectEqual(@as(u8, 1), unit.programmed());
    try std.testing.expectEqual(@as(u8, 1), unit.readOnly());
}

test "the alias pairs reach the regions that follow the selected one" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();
    try unit.prime(&ppb);

    try ppb.writeWord(memmap.mpu.rnr, 2);
    try ppb.writeWord(memmap.mpu.rbar_a1, 0x0200_0000);
    try ppb.writeWord(memmap.mpu.rlar_a1, 0x0200_0FE0 | mpu.field.rlar_enable);
    try ppb.writeWord(memmap.mpu.rbar_a3, 0x4000_0000);
    try ppb.writeWord(memmap.mpu.rlar_a3, 0x4000_0FE0 | mpu.field.rlar_enable);
    try unit.poll(&ppb);

    try std.testing.expectEqual(@as(u32, 0x0200_0000), unit.table[3].base);
    try std.testing.expect(unit.table[3].enabled);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), unit.table[5].base);
    try std.testing.expect(unit.table[5].enabled);
    // Region 4 sat between them and nothing programmed it.
    try std.testing.expect(!unit.table[4].enabled);
}

test "a region with EN clear covers nothing" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();
    try unit.prime(&ppb);

    try ppb.writeWord(memmap.mpu.rnr, 0);
    try ppb.writeWord(memmap.mpu.rbar, 0x2200_0000);
    try ppb.writeWord(memmap.mpu.rlar, 0x2200_1FE0);
    try unit.poll(&ppb);

    try std.testing.expect(!unit.table[0].enabled);
    try std.testing.expect(!unit.table[0].covers(0x2200_0010));
    try std.testing.expectEqual(@as(u32, 0), unit.table[0].bytes());
    try std.testing.expectEqual(@as(u8, 0), unit.programmed());
    try std.testing.expectEqual(@as(?mpu.Region, null), unit.regionFor(0x2200_0010));
}

test "CTRL.ENABLE moving each way is counted once" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();
    try unit.prime(&ppb);

    try unit.poll(&ppb);
    try std.testing.expect(!unit.on());
    try std.testing.expectEqual(@as(u32, 0), unit.enables);

    try ppb.writeWord(memmap.mpu.ctrl, mpu.field.ctrl_enable | mpu.field.ctrl_privdefena);
    try unit.poll(&ppb);
    try unit.poll(&ppb);
    try std.testing.expect(unit.on());
    try std.testing.expect(unit.privilegedDefault());
    try std.testing.expectEqual(@as(u32, 1), unit.enables);
    try std.testing.expectEqual(@as(u32, 0), unit.disables);

    // ra8_mpu_configure disables before it reprogrammes, then re-enables.
    try ppb.writeWord(memmap.mpu.ctrl, 0);
    try unit.poll(&ppb);
    try ppb.writeWord(memmap.mpu.ctrl, mpu.field.ctrl_enable);
    try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 2), unit.enables);
    try std.testing.expectEqual(@as(u32, 1), unit.disables);
}

test "an overlap resolves to the highest-numbered region covering the address" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var unit = mpu.Mpu.init();

    unit.table[1] = mpu.Region.fromPair(0x2200_0000, 0x2200_FFE0 | mpu.field.rlar_enable);
    unit.table[4] = mpu.Region.fromPair(
        0x2200_8000 | mpu.field.rbar_ap_ro,
        0x2200_8FE0 | mpu.field.rlar_enable,
    );

    const inner = unit.regionFor(0x2200_8100) orelse return error.NoRegion;
    try std.testing.expect(inner.read_only);
    const outer = unit.regionFor(0x2200_0100) orelse return error.NoRegion;
    try std.testing.expect(!outer.read_only);
    _ = &ppb;
}

test "a select value beyond the implemented set wraps into it" {
    try std.testing.expectEqual(@as(u8, 0), mpu.geometry.selects(0));
    try std.testing.expectEqual(@as(u8, 7), mpu.geometry.selects(7));
    try std.testing.expectEqual(@as(u8, 0), mpu.geometry.selects(8));
    try std.testing.expectEqual(@as(u8, 1), mpu.geometry.selects(9));
}
