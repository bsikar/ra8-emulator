//! The peripheral clock source selects: what the SREQ -> SRDY handshake
//! answers, and what PRCR eats.
const std = @import("std");
const ra8 = @import("ra8");
const ckcr = ra8.periph.ckcr;
const prcr = ra8.periph.prcr;

/// A protection model with PRC0 already open, the state a driver reaches
/// through RA8_PROTECTED_WRITE before it touches any of these.
fn unlocked() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.key.value | prcr.group.cgc);
    return guard;
}

fn at(index: u32) u32 {
    return ckcr.win_base + index;
}

test "SRDY reads zero until something asks for a switch" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(0), 1));
    try std.testing.expect(unit.quiet());
}

test "SREQ brings SRDY up, which is the wait the driver spins on first" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    unit.write(at(3), 1, ckcr.field.sreq);
    const seen = unit.read(at(3), 1);
    try std.testing.expect(seen & ckcr.field.srdy != 0);
    try std.testing.expect(seen & ckcr.field.sreq != 0);
}

test "dropping SREQ takes SRDY down, which is the second wait" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    unit.write(at(3), 1, ckcr.field.sreq);
    unit.write(at(3), 1, 5 | ckcr.field.sreq);
    unit.write(at(3), 1, 5);
    const seen = unit.read(at(3), 1);
    try std.testing.expectEqual(@as(u32, 5), seen);
    try std.testing.expectEqual(@as(u32, 1), unit.selects[3].switches);
}

test "the source lands whether or not SREQ rides with it" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    unit.write(at(0), 1, 3 | ckcr.field.sreq);
    try std.testing.expectEqual(@as(u8, 3), unit.selects[0].sel);
    unit.write(at(0), 1, 3);
    try std.testing.expectEqual(@as(u8, 3), unit.selects[0].sel);
}

test "SRDY is read only: a store cannot set it and a store cannot hold it up" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    unit.write(at(1), 1, ckcr.field.srdy);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(1), 1));
}

test "the four registers do not share a handshake" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    unit.write(at(0), 1, ckcr.field.sreq);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(2), 1));
    try std.testing.expect(unit.read(at(0), 1) & ckcr.field.srdy != 0);
}

test "a store with PRC0 locked is eaten and the branch does not move" {
    var guard = prcr.Prcr.init();
    var unit = ckcr.Ckcr.init(&guard);
    unit.write(at(3), 1, 5 | ckcr.field.sreq);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(3), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_locked);
}

test "a run that switched nothing stays out of the report" {
    var guard = unlocked();
    var unit = ckcr.Ckcr.init(&guard);
    _ = unit.read(at(0), 1);
    try std.testing.expect(unit.quiet());
    unit.write(at(0), 1, ckcr.field.sreq);
    try std.testing.expect(!unit.quiet());
}
