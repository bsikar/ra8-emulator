//! The ICU event links: routing, the latch, the clear polarity, and the
//! re-pend that reproduces a handler which never took its flag down.
const std = @import("std");
const ra8 = @import("ra8");

const icu = ra8.periph.icu;
const memmap = ra8.core.memmap;

/// A stand-in for the core: the ICU only ever reaches the PPB, so a word map
/// is the whole of what it needs. Its two methods are called through `anytype`
/// from src/periph/icu.zig, so both are pub.
const FakeCore = struct {
    words: std.AutoHashMap(u32, u32),

    fn init(allocator: std.mem.Allocator) FakeCore {
        return .{ .words = std.AutoHashMap(u32, u32).init(allocator) };
    }

    fn deinit(self: *FakeCore) void {
        self.words.deinit();
    }

    pub fn readWord(self: *FakeCore, address: u32) !u32 {
        return self.words.get(address) orelse 0;
    }

    pub fn writeWord(self: *FakeCore, address: u32, value: u32) !void {
        try self.words.put(address, value);
    }
};

fn pendingBits(core: *FakeCore, word: u32) !u32 {
    return core.readWord(memmap.nvic.ispr + 4 * word);
}

test "an event pends the line whose IELSR listens for it" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(35), 4, 0x123);
    try unit.raise(&core, 0x123);

    try std.testing.expect(unit.latched(35));
    try std.testing.expectEqual(@as(u32, 1) << 3, try pendingBits(&core, 1));
    try std.testing.expectEqual(@as(u64, 1), unit.raised);
    try std.testing.expectEqual(@as(u64, 1), unit.pends);
}

test "an event no slot links is counted and dropped" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(35), 4, 0x123);
    try unit.raise(&core, 0x124);

    try std.testing.expectEqual(@as(u64, 1), unit.unlinked);
    try std.testing.expectEqual(@as(u64, 0), unit.pends);
    try std.testing.expectEqual(@as(u32, 0), try pendingBits(&core, 1));
}

test "IELS zero is no link, so event zero matches nothing" {
    var unit = icu.Icu.init();
    try std.testing.expectEqual(@as(?usize, null), unit.slotFor(0));
    unit.write(icu.slotAddress(7), 4, 0);
    try std.testing.expectEqual(@as(?usize, null), unit.slotFor(0));
}

test "the first slot listening for an event owns it" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(9), 4, 0x122);
    unit.write(icu.slotAddress(40), 4, 0x122);
    try unit.raise(&core, 0x122);

    try std.testing.expect(unit.latched(9));
    try std.testing.expect(!unit.latched(40));
}

test "IR is write-zero-to-clear, so a written one leaves it standing" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(2), 4, 0x123);
    try unit.raise(&core, 0x123);
    try std.testing.expect(unit.latched(2));

    // The move a driver makes when it thinks IR is write-one-to-clear.
    unit.write(icu.slotAddress(2), 4, 0x123 | icu.field.ir);
    try std.testing.expect(unit.latched(2));

    unit.write(icu.slotAddress(2), 4, 0x123);
    try std.testing.expect(!unit.latched(2));
}

test "a write keeps the link and the DTC enable, whatever IR does" {
    var unit = icu.Icu.init();
    unit.write(icu.slotAddress(11), 4, 0x080 | icu.field.dtce);
    const value = unit.read(icu.slotAddress(11), 4);
    try std.testing.expectEqual(@as(u32, 0x080), value & icu.field.iels);
    try std.testing.expect(value & icu.field.dtce != 0);
}

test "a still-latched line is pended again at the boundary" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(1), 4, 0x123);
    try unit.raise(&core, 0x123);
    // Entry clears ISPR, the way src/periph/nvic.zig does when it vectors in.
    try core.writeWord(memmap.nvic.ispr, 0);

    try unit.repend(&core);
    try std.testing.expectEqual(@as(u32, 1) << 1, try pendingBits(&core, 0));
    try std.testing.expectEqual(@as(u64, 1), unit.repends);
}

test "a handler that clears IR is not re-entered" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(1), 4, 0x123);
    try unit.raise(&core, 0x123);
    try core.writeWord(memmap.nvic.ispr, 0);
    unit.write(icu.slotAddress(1), 4, 0x123);

    try unit.repend(&core);
    try std.testing.expectEqual(@as(u32, 0), try pendingBits(&core, 0));
    try std.testing.expectEqual(@as(u64, 0), unit.repends);
}

test "a line already pending is not pended twice" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(1), 4, 0x123);
    try unit.raise(&core, 0x123);
    try unit.repend(&core);
    try std.testing.expectEqual(@as(u64, 0), unit.repends);
}

test "an event raised while IR is up latches nothing new" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    unit.write(icu.slotAddress(5), 4, 0x123);
    try unit.raise(&core, 0x123);
    try unit.raise(&core, 0x123);

    try std.testing.expectEqual(@as(u64, 2), unit.raised);
    try std.testing.expectEqual(@as(u64, 1), unit.pends);
}

test "the pend is unconditional, so a line enabled later still takes it" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var unit = icu.Icu.init();

    // Nothing has written ISER: dev would drop this pend and lose the event.
    unit.write(icu.slotAddress(64), 4, 0x122);
    try unit.raise(&core, 0x122);
    try std.testing.expectEqual(@as(u32, 1), try pendingBits(&core, 2));
}

test "an address outside the table answers nothing and changes nothing" {
    var unit = icu.Icu.init();
    unit.write(icu.win_base + icu.win_span, 4, 0x123);
    try std.testing.expectEqual(@as(u32, 0), unit.read(icu.win_base + icu.win_span, 4));
    try std.testing.expectEqual(@as(?usize, null), unit.slotFor(0x123));
    try std.testing.expect(unit.quiet());
}

test "slot n vectors through exception 16 + n" {
    try std.testing.expectEqual(@as(u16, 16), icu.exceptionFor(0));
    try std.testing.expectEqual(@as(u16, 51), icu.exceptionFor(35));
    try std.testing.expectEqual(icu.win_base + 4 * 35, icu.slotAddress(35));
}
