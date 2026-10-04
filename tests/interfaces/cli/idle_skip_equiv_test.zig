//! RA8EMU-185's done condition: an idle-heavy image reaches the same state
//! at the same virtual time with and without idle fast-forward. The image is
//! built here: a reset handler that sleeps in WFI forever and a SysTick
//! handler that counts its ticks in RAM, with SysTick slower than a chunk so
//! the skip really widens the sleeping stretches.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const zig_run = ra8.board.zig_run;
const cpu_boot = ra8.core.cpu.boot;

const base = memmap.sram_base;
const reset_at = base + 0x40;
const handler_at = base + 0x48;
const counter_at = base + 0x100;
const chunk: u32 = 5_000;
const period: u32 = 200_000;
const budget: u64 = 1_000_000;

/// What one run ended with.
const Ended = struct {
    status: u8,
    ran: u64,
    elapsed: u64,
    ticks: u64,
    count: u32,
    pc: u32,
    closes: u32,
};

/// The run's Clock with a count of the stretches it closed.
const Counted = struct {
    clock: *zig_run.Clock,
    closes: u32 = 0,

    fn boundary(self: *Counted, skip: bool) cpu_boot.Boundary {
        return .{ .context = self, .widthFn = width, .closeFn = close, .sleepFn = if (skip) asleep else null };
    }

    fn width(context: *anyopaque) u32 {
        const self: *Counted = @ptrCast(@alignCast(context));
        return self.clock.width();
    }

    fn asleep(context: *anyopaque, normal: u32) u32 {
        const self: *Counted = @ptrCast(@alignCast(context));
        return self.clock.asleepWidth(normal);
    }

    fn close(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Counted = @ptrCast(@alignCast(context));
        self.closes += 1;
        try self.clock.close(instructions);
    }
};

/// Vectors, `wfi; b .-2`, and a handler that adds one to the counter.
fn load(core: anytype) !void {
    try core.writeWord(base, memmap.sram_end);
    try core.writeWord(base + 4, reset_at | 1);
    try core.writeWord(base + 15 * 4, handler_at | 1);
    try core.writeWord(reset_at, 0xE7FD_BF30);
    try core.writeWord(handler_at, 0x6801_4802);
    try core.writeWord(handler_at + 4, 0x6001_3101);
    try core.writeWord(handler_at + 8, 0xBF00_4770);
    try core.writeWord(handler_at + 12, counter_at);
    try core.writeWord(counter_at, 0);
    try core.writeWord(memmap.syst.rvr, period - 1);
    try core.writeWord(memmap.syst.cvr, 0);
    try core.writeWord(memmap.syst.csr, 0x7);
}

fn runIdler(skip: bool) !Ended {
    var core = try ra8.core.engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try load(core);
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&core);
    var timebase: ra8.periph.clocks.Clocks = .{ .per_chunk = chunk };
    var clock: zig_run.Clock = .{ .memory = .{ .engine = core }, .board = &board, .timebase = &timebase, .idle_skip = skip };
    var counted: Counted = .{ .clock = &clock };
    var ran: u64 = 0;
    var final: cpu_boot.Regs = .{};
    var output: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&output);
    const status = try cpu_boot.start(stream.writer(), .zig, .{ .engine = core }, &board.bus, base, budget, &ran, .{ .boundary = counted.boundary(skip), .final = &final });
    return .{
        .status = status,
        .ran = ran,
        .elapsed = timebase.elapsed,
        .ticks = timebase.ticks,
        .count = try core.readWord(counter_at),
        .pc = final.pc,
        .closes = counted.closes,
    };
}

test "an idle image ends in the same state at the same virtual time with and without the skip" {
    const stepped = try runIdler(false);
    const skipped = try runIdler(true);
    try std.testing.expect(stepped.count > 0);
    try std.testing.expectEqual(stepped.status, skipped.status);
    try std.testing.expectEqual(stepped.ran, skipped.ran);
    try std.testing.expectEqual(stepped.elapsed, skipped.elapsed);
    try std.testing.expectEqual(stepped.ticks, skipped.ticks);
    try std.testing.expectEqual(stepped.count, skipped.count);
    try std.testing.expectEqual(stepped.pc, skipped.pc);
}

test "the skip closes fewer boundaries on an idle image" {
    const stepped = try runIdler(false);
    const skipped = try runIdler(true);
    try std.testing.expect(skipped.closes < stepped.closes);
}
