//! Tests for src/periph/clocks.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const mod = ra8.periph.clocks;

const Clocks = mod.Clocks;
const Wrapped = mod.Wrapped;
const csr_countflag = mod.csr_countflag;
const csr_enable = mod.csr_enable;
const csr_tickint = mod.csr_tickint;
const demcr_trcena = mod.demcr_trcena;
const dwt_ctrl_cyccntena = mod.dwt_ctrl_cyccntena;
const icsr_pendstset = mod.icsr_pendstset;
const wrap = mod.wrap;

/// A stand-in for the PPB words this model reads and writes, so the model can
/// be tested without a CPU behind it.
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

    fn armCycleCounter(self: *FakePpb) !void {
        try self.writeWord(memmap.scb.demcr, demcr_trcena);
        try self.writeWord(memmap.dwt.ctrl, dwt_ctrl_cyccntena);
    }

    fn armSysTick(self: *FakePpb, reload: u32, csr: u32) !void {
        try self.writeWord(memmap.syst.rvr, reload);
        try self.writeWord(memmap.syst.cvr, reload);
        try self.writeWord(memmap.syst.csr, csr);
    }
};
test "the cycle counter stays where the firmware left it until it is enabled" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var clocks = Clocks{};

    try clocks.advance(&ppb, 1000);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.dwt.cyccnt));

    // The trace subsystem alone is not enough: CYCCNTENA gates it too.
    try ppb.writeWord(memmap.scb.demcr, demcr_trcena);
    try clocks.advance(&ppb, 1000);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.dwt.cyccnt));
    try std.testing.expectEqual(@as(u64, 0), clocks.cycles);
}

test "an enabled cycle counter is charged the chunk it ran" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armCycleCounter();
    var clocks = Clocks{};

    try clocks.advance(&ppb, 500_000);
    try clocks.advance(&ppb, 500_000);
    try std.testing.expectEqual(@as(u32, 1_000_000), try ppb.readWord(memmap.dwt.cyccnt));
    try std.testing.expectEqual(@as(u64, 1_000_000), clocks.cycles);
}

test "a firmware reset of the cycle counter is honoured and the count resumes" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armCycleCounter();
    var clocks = Clocks{};

    try clocks.advance(&ppb, 400);
    try ppb.writeWord(memmap.dwt.cyccnt, 0); // what ra8_time_init does.
    try clocks.advance(&ppb, 400);
    try std.testing.expectEqual(@as(u32, 400), try ppb.readWord(memmap.dwt.cyccnt));
}

test "a disabled SysTick does not count" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(999, 0);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 5000);
    try std.testing.expectEqual(@as(u32, 999), try ppb.readWord(memmap.syst.cvr));
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.syst.csr) & csr_countflag);
}

test "a chunk shorter than the counter just decrements it" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(999, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 100);
    try std.testing.expectEqual(@as(u32, 899), try ppb.readWord(memmap.syst.cvr));
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.syst.csr) & csr_countflag);
}

test "a wrap reloads the counter and raises COUNTFLAG" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 150);
    try std.testing.expectEqual(@as(u64, 1), clocks.ticks);
    try std.testing.expectEqual(@as(u32, 49), try ppb.readWord(memmap.syst.cvr));
    try std.testing.expect(try ppb.readWord(memmap.syst.csr) & csr_countflag != 0);
}

test "COUNTFLAG is readable for one chunk and cleared at the next boundary" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 150);
    try std.testing.expect(try ppb.readWord(memmap.syst.csr) & csr_countflag != 0);
    try clocks.advance(&ppb, 10);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.syst.csr) & csr_countflag);
    // Clearing the flag leaves the rest of SYST_CSR alone.
    try std.testing.expect(try ppb.readWord(memmap.syst.csr) & csr_enable != 0);
}

test "every period inside one chunk is counted" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 1000);
    try std.testing.expectEqual(@as(u64, 10), clocks.ticks);
}

test "a wrap pends the SysTick exception only when TICKINT is set" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 150);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.scb.icsr) & icsr_pendstset);
    try std.testing.expectEqual(@as(u64, 0), clocks.pends);

    try ppb.armSysTick(99, csr_enable | csr_tickint);
    try clocks.advance(&ppb, 150);
    try std.testing.expect(try ppb.readWord(memmap.scb.icsr) & icsr_pendstset != 0);
    try std.testing.expectEqual(@as(u64, 1), clocks.pends);
}

test "a zero reload never wraps" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(0, csr_enable | csr_tickint);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 5000);
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u32, 0), try ppb.readWord(memmap.scb.icsr) & icsr_pendstset);
}

test "the counter lands where the architecture says after a long chunk" {
    // 24-bit reload, a chunk longer than several periods: the landing value is
    // the reload minus however far past the last wrap the chunk went.
    try std.testing.expectEqual(Wrapped{ .value = 7, .periods = 0 }, wrap(10, 99, 3));
    try std.testing.expectEqual(Wrapped{ .value = 99, .periods = 1 }, wrap(10, 99, 11));
    try std.testing.expectEqual(Wrapped{ .value = 98, .periods = 1 }, wrap(10, 99, 12));
    try std.testing.expectEqual(Wrapped{ .value = 99, .periods = 2 }, wrap(10, 99, 111));
}
