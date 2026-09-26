//! IPCSEMn and the NMI doorbells: the lock is taken by the read itself.
const std = @import("std");
const ra8 = @import("ra8");
const ipc = ra8.periph.ipc;
const sync = ra8.periph.ipc_sync;

const sem_lock = sync.sem.lock;
const nmi_bit = sync.nmi.bit;

fn semAddress(index: usize) u32 {
    return ipc.win_base + sync.semOffset(index);
}

fn nmiAddress(unit: usize, register: u32) u32 {
    return ipc.win_base + sync.nmiOffset(unit, register);
}

test "a read of a free semaphore answers zero and takes the lock" {
    var unit = ipc.Ipc.init();
    try std.testing.expectEqual(@as(u32, 0), unit.read(semAddress(0), 4));
    try std.testing.expect(unit.locks.semaphores[0].locked);
    try std.testing.expectEqual(@as(u32, 1), unit.locks.semaphores[0].takes);
}

test "the second claimant is told it lost" {
    var unit = ipc.Ipc.init();
    _ = unit.read(semAddress(3), 4);
    try std.testing.expectEqual(sem_lock, unit.read(semAddress(3), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.locks.semaphores[3].contentions);
    try std.testing.expectEqual(@as(u32, 1), unit.locks.contentions());
}

test "a contended read leaves the lock standing for the holder" {
    var unit = ipc.Ipc.init();
    _ = unit.read(semAddress(5), 4);
    _ = unit.read(semAddress(5), 4);
    try std.testing.expect(unit.locks.semaphores[5].locked);
    try std.testing.expectEqual(@as(usize, 1), unit.locks.held());
}

test "writing a one releases the lock" {
    var unit = ipc.Ipc.init();
    _ = unit.read(semAddress(7), 4);
    unit.write(semAddress(7), 4, sem_lock);
    try std.testing.expect(!unit.locks.semaphores[7].locked);
    try std.testing.expectEqual(@as(u32, 1), unit.locks.semaphores[7].releases);
    try std.testing.expectEqual(@as(u32, 0), unit.read(semAddress(7), 4));
}

test "writing a zero releases nothing" {
    var unit = ipc.Ipc.init();
    _ = unit.read(semAddress(2), 4);
    unit.write(semAddress(2), 4, 0);
    try std.testing.expect(unit.locks.semaphores[2].locked);
    try std.testing.expectEqual(@as(u32, 0), unit.locks.semaphores[2].releases);
}

test "a release nobody was holding is counted apart" {
    var unit = ipc.Ipc.init();
    unit.write(semAddress(1), 4, sem_lock);
    try std.testing.expectEqual(@as(u32, 1), unit.locks.semaphores[1].stray_releases);
    try std.testing.expectEqual(@as(u32, 0), unit.locks.semaphores[1].releases);
}

test "the sixteen semaphores are separate locks" {
    var unit = ipc.Ipc.init();
    _ = unit.read(semAddress(0), 4);
    try std.testing.expectEqual(@as(u32, 0), unit.read(semAddress(15), 4));
    try std.testing.expectEqual(@as(usize, 2), unit.locks.held());
    try std.testing.expectEqual(sem_lock, unit.read(semAddress(15), 4));
}

test "the semaphore file ends before the gap at 0x40" {
    try std.testing.expect(sync.decode(sync.semOffset(15)) != null);
    try std.testing.expect(sync.decode(sync.sem.span) == null);
}

test "the gap above the semaphores is still shadow" {
    var unit = ipc.Ipc.init();
    const address = ipc.win_base + 0x40;
    unit.write(address, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.read(address, 4));
}

test "a narrow read of a semaphore still takes the lock" {
    var unit = ipc.Ipc.init();
    try std.testing.expectEqual(@as(u32, 0), unit.read(semAddress(4), 1));
    try std.testing.expect(unit.locks.semaphores[4].locked);
    try std.testing.expectEqual(@as(u32, 1), unit.read(semAddress(4), 1));
}

test "NMISET raises the status bit the receiver polls" {
    var unit = ipc.Ipc.init();
    try std.testing.expectEqual(@as(u32, 0), unit.read(nmiAddress(0, sync.nmi.off_sta), 4));
    unit.write(nmiAddress(0, sync.nmi.off_set), 4, nmi_bit);
    try std.testing.expectEqual(nmi_bit, unit.read(nmiAddress(0, sync.nmi.off_sta), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.locks.doorbells[0].sends);
}

test "NMICLR drops it again" {
    var unit = ipc.Ipc.init();
    unit.write(nmiAddress(1, sync.nmi.off_set), 4, nmi_bit);
    unit.write(nmiAddress(1, sync.nmi.off_clr), 4, nmi_bit);
    try std.testing.expectEqual(@as(u32, 0), unit.read(nmiAddress(1, sync.nmi.off_sta), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.locks.doorbells[1].acks);
}

test "a second send onto a standing request is the same bit, not a second NMI" {
    var unit = ipc.Ipc.init();
    unit.write(nmiAddress(0, sync.nmi.off_set), 4, nmi_bit);
    unit.write(nmiAddress(0, sync.nmi.off_set), 4, nmi_bit);
    try std.testing.expectEqual(@as(u32, 2), unit.locks.doorbells[0].sends);
    try std.testing.expectEqual(@as(u32, 1), unit.locks.doorbells[0].coalesced);
    try std.testing.expectEqual(nmi_bit, unit.read(nmiAddress(0, sync.nmi.off_sta), 4));
}

test "the two NMI units are separate doorbells" {
    var unit = ipc.Ipc.init();
    unit.write(nmiAddress(0, sync.nmi.off_set), 4, nmi_bit);
    try std.testing.expectEqual(@as(u32, 0), unit.read(nmiAddress(1, sync.nmi.off_sta), 4));
    try std.testing.expect(unit.locks.doorbells[0].pending);
    try std.testing.expect(!unit.locks.doorbells[1].pending);
}

test "a store at NMISTA is refused, the way a status register is" {
    var unit = ipc.Ipc.init();
    unit.write(nmiAddress(0, sync.nmi.off_sta), 4, nmi_bit);
    try std.testing.expectEqual(@as(u32, 0), unit.read(nmiAddress(0, sync.nmi.off_sta), 4));
    try std.testing.expect(!unit.locks.doorbells[0].pending);
}

test "a zero written at SET or CLR says nothing" {
    var unit = ipc.Ipc.init();
    unit.write(nmiAddress(0, sync.nmi.off_set), 4, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.locks.doorbells[0].sends);
    unit.write(nmiAddress(0, sync.nmi.off_set), 4, nmi_bit);
    unit.write(nmiAddress(0, sync.nmi.off_clr), 4, 0);
    try std.testing.expect(unit.locks.doorbells[0].pending);
}

test "the unused words in an NMI window stay shadow" {
    var unit = ipc.Ipc.init();
    const address = ipc.win_base + sync.nmiOffset(0, 0x0C);
    unit.write(address, 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), unit.read(address, 4));
}

test "an untouched block stays out of the report, a taken lock does not" {
    var unit = ipc.Ipc.init();
    try std.testing.expect(unit.quiet());
    _ = unit.read(semAddress(9), 4);
    try std.testing.expect(!unit.quiet());
}

test "the channel windows are untouched by all of this" {
    var unit = ipc.Ipc.init();
    _ = unit.read(semAddress(0), 4);
    unit.write(nmiAddress(0, sync.nmi.off_set), 4, nmi_bit);
    for (&unit.channels) |*channel| {
        try std.testing.expect(channel.quiet());
    }
}
