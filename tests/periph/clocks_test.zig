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
const observe = mod.observe;
const Observed = mod.Observed;

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

test "an armed SysTick asks for a boundary one period wide" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(8_399, csr_enable | csr_tickint);
    const clocks = Clocks{};
    try std.testing.expectEqual(@as(u32, 8_400), clocks.period(&ppb));
}

test "a disabled SysTick asks for nothing" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(8_399, 0);
    const clocks = Clocks{};
    try std.testing.expectEqual(@as(u32, 0), clocks.period(&ppb));
}

test "a zero reload never wraps, so it asks for nothing" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(0, csr_enable | csr_tickint);
    const clocks = Clocks{};
    try std.testing.expectEqual(@as(u32, 0), clocks.period(&ppb));
}

test "the period a counting SysTick asks for ignores TICKINT" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(999, csr_enable);
    const clocks = Clocks{};
    try std.testing.expectEqual(@as(u32, 1_000), clocks.period(&ppb));
}

test "one boundary per period pends every period rather than collapsing them" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    var collapsed = Clocks{};
    try ppb.armSysTick(999, csr_enable | csr_tickint);
    try collapsed.advance(&ppb, 6_000);
    try std.testing.expectEqual(@as(u64, 6), collapsed.ticks);
    try std.testing.expectEqual(@as(u64, 1), collapsed.pends);

    var followed = Clocks{};
    try ppb.armSysTick(999, csr_enable | csr_tickint);
    for (0..6) |_| try followed.advance(&ppb, 1_000);
    try std.testing.expectEqual(@as(u64, 6), followed.ticks);
    try std.testing.expectEqual(@as(u64, 6), followed.pends);
}

test "a stretch covering one period tells the firmware about all of it" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(999, csr_enable | csr_tickint);
    var clocks = Clocks{};

    // A period is reload + 1 ticks, so exactly one wrap.
    try clocks.advance(&ppb, 1000);
    try std.testing.expectEqual(@as(u64, 1), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 1), clocks.pends);
    try std.testing.expectEqual(@as(u64, 0), clocks.collapsed);
}

test "a stretch covering several periods raises for one and counts the rest" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable | csr_tickint);
    var clocks = Clocks{};

    // Ten periods of 100 ticks inside one stretch. COUNTFLAG and the pend
    // bit are single latches and the handler cannot run part way through, so
    // the firmware is told about one of the ten.
    try clocks.advance(&ppb, 1000);
    try std.testing.expectEqual(@as(u64, 10), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 1), clocks.pends);
    try std.testing.expectEqual(@as(u64, 9), clocks.collapsed);
}

test "the collapse is counted whether or not the firmware asked for the interrupt" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    // TICKINT clear: no pend, but COUNTFLAG is still a single bit, so a
    // firmware polling it loses the same periods.
    try ppb.armSysTick(99, csr_enable);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 500);
    try std.testing.expectEqual(@as(u64, 5), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 0), clocks.pends);
    try std.testing.expectEqual(@as(u64, 4), clocks.collapsed);
}

test "a stretch too short to wrap owes the firmware nothing" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(999, csr_enable | csr_tickint);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 400);
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 0), clocks.collapsed);
}

test "a disabled counter collapses nothing" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(9, csr_tickint);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 10_000);
    try std.testing.expectEqual(@as(u64, 0), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 0), clocks.collapsed);
}

test "the collapse accumulates across stretches" {
    var ppb = FakePpb.init(std.testing.allocator);
    defer ppb.deinit();
    try ppb.armSysTick(99, csr_enable | csr_tickint);
    var clocks = Clocks{};

    try clocks.advance(&ppb, 300);
    try clocks.advance(&ppb, 300);
    try std.testing.expectEqual(@as(u64, 6), clocks.ticks);
    try std.testing.expectEqual(@as(u64, 2), clocks.pends);
    try std.testing.expectEqual(@as(u64, 4), clocks.collapsed);
}

test "starting the counter ends the stretch, because the period it arms is narrower than it" {
    // The arming store the whole hook exists for: `ra8_systick_configure`
    // stages the reload with the counter stopped, then sets ENABLE, and the
    // stretch in flight was cut when nothing was armed.
    try std.testing.expectEqual(
        Observed.rearm,
        observe(memmap.syst.csr, csr_enable | csr_tickint, 0, 8_399),
    );
}

test "staging a reload with the counter stopped ends nothing" {
    // Period is zero either way, so nothing is swallowed and the driver can
    // stage the reload as freely as it likes.
    try std.testing.expectEqual(Observed.none, observe(memmap.syst.rvr, 8_399, 0, 0));
}

test "starting a counter with a zero reload ends nothing" {
    // A zero reload never wraps, so the boundary cannot be narrowed by it.
    try std.testing.expectEqual(Observed.none, observe(memmap.syst.csr, csr_enable, 0, 0));
}

test "re-arming a running counter with a new reload ends the stretch" {
    // The retune path: ra8_threadx_systick_retune reprogrammes SYST_RVR off
    // the live CPUCLK0 while the kernel tick is already running.
    try std.testing.expectEqual(
        Observed.rearm,
        observe(memmap.syst.rvr, 999_999, csr_enable | csr_tickint, 8_399),
    );
}

test "writing the same reload back leaves the period where it was" {
    try std.testing.expectEqual(
        Observed.none,
        observe(memmap.syst.rvr, 8_399, csr_enable, 8_399),
    );
}

test "the reload comparison is the 24-bit field, not the word" {
    // SYST_RVR is 24 bits; the bits above it are not the reload, so a store
    // that only changes them changes no period.
    try std.testing.expectEqual(
        Observed.none,
        observe(memmap.syst.rvr, 0xFF00_0000 | 8_399, csr_enable, 8_399),
    );
}

test "a control store that keeps the counter running ends nothing" {
    // Folding TICKINT in mid-run does not re-size anything, and the stretch
    // in flight was already cut from this period.
    try std.testing.expectEqual(
        Observed.none,
        observe(memmap.syst.csr, csr_enable | csr_tickint, csr_enable, 8_399),
    );
}

test "stopping the counter ends nothing, because a stretch cut from a period swallows none" {
    try std.testing.expectEqual(Observed.none, observe(memmap.syst.csr, 0, csr_enable, 8_399));
}

test "a store anywhere else in the window ends nothing" {
    // SYST_CVR is written by the model at every boundary and by a driver
    // restarting a period, and neither changes how wide the period is.
    try std.testing.expectEqual(Observed.none, observe(memmap.syst.cvr, 0, csr_enable, 8_399));
    try std.testing.expectEqual(Observed.none, observe(memmap.syst.calib, 0, csr_enable, 8_399));
}

test "one arming store ends one boundary" {
    var clock = Clocks{};
    try std.testing.expect(!clock.took());
    clock.armed();
    try std.testing.expectEqual(@as(u64, 1), clock.rearms);
    try std.testing.expect(clock.took());
    // Taken once: the latch does not end the boundary after it as well.
    try std.testing.expect(!clock.took());
    try std.testing.expectEqual(@as(u64, 1), clock.rearms);
}
