//! What enforcement caught, and what it did with it.
const std = @import("std");
const ra8 = @import("ra8");
const mpu_fault = ra8.periph.mpu_fault;

test "a latch with nothing armed and nothing refused stays out of the report" {
    const latch = mpu_fault.Latch{};
    try std.testing.expect(latch.quiet());
    try std.testing.expectEqual(@as(?mpu_fault.Violation, null), latch.pending);
}

test "arming alone is enough to be reported" {
    var latch = mpu_fault.Latch{};
    latch.arms += 1;
    try std.testing.expect(!latch.quiet());
}

test "the first refused store is the one the run stops on" {
    var latch = mpu_fault.Latch{};
    try std.testing.expect(latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0040 }));
    try std.testing.expectEqual(@as(u64, 1), latch.violations);
    try std.testing.expectEqual(@as(u64, 0), latch.coalesced);
}

test "the rest of an access already latched is not a second violation" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0040 });
    // A store multiple puts one word per hook call: the words after the
    // first belong to the access that already stopped the run.
    try std.testing.expect(!latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0044 }));
    try std.testing.expect(!latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0048 }));
    try std.testing.expectEqual(@as(u64, 1), latch.violations);
    try std.testing.expectEqual(@as(u64, 2), latch.coalesced);
}

test "taking the violation gives back the store that made it" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0040 });
    const hit = latch.take().?;
    try std.testing.expectEqual(@as(u32, 0x0200_1234), hit.pc);
    try std.testing.expectEqual(@as(u32, 0x2200_0040), hit.address);
}

test "a violation is taken once" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0040 });
    _ = latch.take();
    try std.testing.expectEqual(@as(?mpu_fault.Violation, null), latch.take());
}

test "the next access after one was taken latches again" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0040 });
    _ = latch.take();
    try std.testing.expect(latch.record(.{ .pc = 0x0200_2000, .address = 0x2200_0100 }));
    try std.testing.expectEqual(@as(u64, 2), latch.violations);
    try std.testing.expectEqual(@as(u64, 0), latch.coalesced);
}

test "MMFSR names a data access violation with MMFAR standing" {
    const status = mpu_fault.mmfsr.daccviol | mpu_fault.mmfsr.mmarvalid;
    try std.testing.expectEqual(@as(u32, 0x82), status);
    // A fetch refused by the MPU is a different bit, and this model does not
    // check one: nothing here sets IACCVIOL.
    try std.testing.expectEqual(@as(u32, 1), mpu_fault.mmfsr.iaccviol);
}

test "MemManage is exception 4" {
    try std.testing.expectEqual(@as(u16, 4), mpu_fault.exception);
}
