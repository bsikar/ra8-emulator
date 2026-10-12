//! Covers architectural slots and canonical count stops in count.zig.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const Fake = @import("exception/fake_source.zig").Fake;
const cpu_mod = ra8.chip.core.cpu.cpu;
const Cpu = cpu_mod.Cpu;
const Stop = cpu_mod.Stop;
const QuietSource = ra8.chip.core.cpu.exception.quiet_source.QuietSource;
const BlockCache = ra8.chip.core.cpu.decode.block_cache.BlockCache;

const Rig = struct {
    ram: fixture.Ram = .{},
    fake: Fake = .{},
    quiet: QuietSource = undefined,
    cache: *BlockCache = undefined,
    cpu: Cpu = undefined,

    fn init(self: *Rig, code: []const u16, fast: bool) !void {
        for (code, 0..) |half, i| self.ram.putHalf(fixture.code + @as(u32, @intCast(i * 2)), half);
        self.cpu = try fixture.boot(&self.ram);
        self.quiet = .{ .inner = self.fake.source(), .memory = self.ram.view() };
        self.cache = try std.testing.allocator.create(BlockCache);
        self.cache.init();
        self.cpu.source = self.fake.source();
        if (fast) {
            self.cpu.bus = self.quiet.bus();
            self.cpu.source = self.quiet.source();
            self.cpu.quiet = &self.quiet;
            self.cpu.blocks = self.cache;
        }
    }

    fn deinit(self: *Rig) void {
        std.testing.allocator.destroy(self.cache);
    }
};

fn same(a: *const Cpu, b: *const Cpu) !void {
    try std.testing.expect(std.meta.eql(a.regs, b.regs));
    try std.testing.expectEqual(a.retired, b.retired);
    try std.testing.expectEqual(a.slots, b.slots);
    try std.testing.expectEqual(a.sync_entries, b.sync_entries);
    try std.testing.expectEqual(a.retired, a.slots - a.sync_entries);
}

/// Loops whose last flag setter moves, so its flags reach the head: an
/// up-count, a down-count, and an up-count followed by a MOVS that rewrites
/// N and Z but leaves the ADDS carry and overflow standing.
const moving_loops = [_][]const u16{
    &.{ 0x3301, 0xE7FD },
    &.{ 0x3B01, 0xE7FD },
    &.{ 0x3301, 0x2105, 0xE7FC },
};

/// Fast and slow cores run `code` from `start` through the same stops and
/// agree at each; one straight fast run then agrees with both.
fn agree(code: []const u16, start: u32, budgets: []const u64) !void {
    var fast = Rig{};
    try fast.init(code, true);
    defer fast.deinit();
    var slow = Rig{};
    try slow.init(code, false);
    defer slow.deinit();
    fast.cpu.regs.low[3] = start;
    slow.cpu.regs.low[3] = start;
    for (budgets) |n| {
        try std.testing.expectEqual(Stop.count, fast.cpu.run(n));
        try std.testing.expectEqual(Stop.count, slow.cpu.run(n));
        try same(&slow.cpu, &fast.cpu);
    }
    try std.testing.expectEqual(@as(u64, 1000), slow.cpu.slots);
    var straight = Rig{};
    try straight.init(code, true);
    defer straight.deinit();
    straight.cpu.regs.low[3] = start;
    try std.testing.expectEqual(Stop.count, straight.cpu.run(1000));
    try same(&straight.cpu, &fast.cpu);
    // The fast path did skip: block reuses stay well short of the trips.
    try std.testing.expect(straight.cache.reused * 10 < 1000 / code.len * 9);
}

test "CPU foundation straight split and skipped counts match at every flag boundary" {
    // Each start is 16 trips from a zero, carry or sign crossing one way.
    const starts = [_]u32{ 0, 0x10, 0x7FFF_FFF0, 0x8000_0010, 0xFFFF_FFF0 };
    // Stops on both sides of trip 16 of a two-slot and of a three-slot trip.
    const split = [_]u64{ 28, 2, 2, 2, 11, 1, 1, 1, 1, 1, 1, 949 };
    for (moving_loops) |code| for (starts) |start| {
        try agree(code, start, &split);
        // One stretch that lands on the head straight after the crossing
        // trip, the one head where its carry or overflow shows, then on the
        // next: a skip that ran through the crossing would leave them stale.
        const trip: u64 = code.len;
        try agree(code, start, &.{ 16 * trip, trip, 1000 - 17 * trip });
        try agree(code, start, &.{ 15 * trip, trip, trip, 1000 - 17 * trip });
    };
}

test "CPU foundation count target bounds skipped bodies and precedes guards" {
    for ([_]u64{ 0, 1, 2, 7, 1000 }) |target| {
        var fast = Rig{};
        try fast.init(&.{ 0xBF00, 0xE7FD }, true);
        defer fast.deinit();
        var slow = Rig{};
        try slow.init(&.{ 0xBF00, 0xE7FD }, false);
        defer slow.deinit();
        try std.testing.expectEqual(Stop.count, fast.cpu.runToCount(2000, target));
        try std.testing.expectEqual(Stop.count, slow.cpu.run(target));
        try same(&slow.cpu, &fast.cpu);
        try std.testing.expectEqual(target, fast.cpu.slots);
    }
    var rig = Rig{};
    try rig.init(&.{0xBF00}, false);
    defer rig.deinit();
    var held = Hold{};
    rig.cpu.fetch_guard = .{ .context = &held, .holdsFn = Hold.holds };
    _ = rig.cpu.runToCount(100, 0);
    try std.testing.expectEqual(@as(u32, 0), held.asked);
    _ = rig.cpu.run(100);
    try std.testing.expectEqual(@as(u32, 1), held.asked);
    try std.testing.expectEqual(@as(u64, 0), rig.cpu.slots);
}

const Hold = struct {
    asked: u32 = 0,
    fn holds(ctx: *anyopaque, _: u32) bool {
        const self: *Hold = @ptrCast(@alignCast(ctx));
        self.asked += 1;
        return true;
    }
};

test "CPU foundation count stop polls after the phase boundary without charging entry" {
    var rig = Rig{};
    try rig.init(&.{ 0xBF00, 0xE7FD }, true);
    defer rig.deinit();
    try std.testing.expectEqual(Stop.count, rig.cpu.runToCount(4, 4));
    try std.testing.expectEqual(fixture.code, rig.cpu.regs.pc);
    // Stand in for CPU1's turn and the board tick: a pend at the boundary.
    rig.fake.pending = .{ .number = 11, .priority = 0 };
    try std.testing.expectEqual(Stop.count, rig.cpu.runToCount(100, 4));
    try std.testing.expectEqual(fixture.handler, rig.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 1), rig.fake.taken);
    try std.testing.expectEqual(@as(u64, 4), rig.cpu.slots);
    try std.testing.expectEqual(@as(u64, 0), rig.cpu.sync_entries);
}

test "CPU foundation synchronous fault slots match straight and split execution" {
    var a = Rig{};
    try a.init(&.{0xDE00}, true); // UDF enters HardFault without retiring.
    defer a.deinit();
    var b = Rig{};
    try b.init(&.{0xDE00}, false);
    defer b.deinit();
    for ([_]*Rig{ &a, &b }) |rig| {
        rig.ram.putWord(fixture.base + 3 * 4, fixture.handler | 1);
        rig.ram.putHalf(fixture.handler, 0xE7FE);
    }
    try std.testing.expectEqual(Stop.count, a.cpu.run(10));
    try std.testing.expectEqual(Stop.count, b.cpu.runToCount(20, 1));
    try std.testing.expectEqual(fixture.handler, b.cpu.regs.pc);
    try std.testing.expectEqual(@as(u64, 0), b.cpu.retired);
    try std.testing.expectEqual(@as(u64, 1), b.cpu.sync_entries);
    try std.testing.expectEqual(Stop.count, b.cpu.run(9));
    try same(&a.cpu, &b.cpu);
    try std.testing.expectEqual(@as(u64, 10), a.cpu.slots);
    try std.testing.expectEqual(@as(u64, 9), a.cpu.retired);
}

test "CPU foundation sleep tails and terminal stops consume no slots" {
    var rig = Rig{};
    try rig.init(&.{ 0xBF30, 0xBE00 }, false); // WFI then BKPT.
    defer rig.deinit();
    try std.testing.expectEqual(Stop.count, rig.cpu.runToCount(1000, 1));
    try std.testing.expectEqual(@as(u64, 1), rig.cpu.slots);
    try std.testing.expectEqual(ra8.chip.core.cpu.exception.sleep.Wait.interrupt, rig.cpu.waiting.?);
    try std.testing.expectEqual(Stop.count, rig.cpu.run(1000));
    try std.testing.expectEqual(@as(u64, 1), rig.cpu.slots);
    rig.cpu.waiting = null;
    rig.ram.putWord(0xE000_EDF0, 1); // Halting debug on BKPT.
    try std.testing.expectEqual(Stop{ .breakpoint = fixture.code + 2 }, rig.cpu.run(10));
    try std.testing.expectEqual(@as(u64, 1), rig.cpu.slots);
    try std.testing.expectEqual(@as(u64, 1), rig.cpu.retired);
    rig.ram.putHalf(fixture.code + 2, 0xBA80); // Undecoded instruction.
    try std.testing.expect(rig.cpu.step() != null);
    try std.testing.expectEqual(@as(u64, 1), rig.cpu.slots);
}

test "CPU foundation count stop wakes before stopping without executing next instruction" {
    var rig = Rig{};
    try rig.init(&.{ 0xBF20, 0x3301 }, false); // WFE then ADDS.
    defer rig.deinit();
    _ = rig.cpu.runToCount(100, 1);
    rig.cpu.event = true;
    try std.testing.expectEqual(Stop.count, rig.cpu.runToCount(100, 1));
    try std.testing.expectEqual(@as(u64, 1), rig.cpu.slots);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.regs.low[3]);
    try std.testing.expect(!rig.cpu.event);
    try std.testing.expect(rig.cpu.waiting == null);
}
