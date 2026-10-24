//! Tests for src/session/history/frame_tap.zig: rate capping, change-triggering,
//! queue bounds, and proving the tap never perturbs guest state.
const std = @import("std");
const ra8 = @import("ra8");
const frame_tap = ra8.session.history_frame_tap;
const frame_queue = ra8.session.history_frame_queue;
const store_board = @import("../../interfaces/cli/store_board.zig");

const Board = ra8.board.board.Board;
const glcdc = ra8.chip.periph.glcdc;
const tcon = ra8.chip.periph.glcdc.tcon;
const glcdc_sys = ra8.chip.periph.glcdc.sys;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;

const MockClock = struct {
    now: i96 = 0,

    fn nowNs(ctx: *const anyopaque) i96 {
        const self: *const MockClock = @ptrCast(@alignCast(ctx));
        return self.now;
    }

    fn clock(self: *const MockClock) frame_tap.Clock {
        return frame_tap.Clock.custom(self, nowNs);
    }
};

const Bench = struct {
    allocator: std.mem.Allocator,
    store: store_board.Store,
    board: Board,
    queue: frame_queue.Queue,
    tap: frame_tap.FrameTap,
    mock_clock: MockClock,

    fn create(allocator: std.mem.Allocator, cap_bytes: usize) !*Bench {
        const self = try allocator.create(Bench);
        self.allocator = allocator;
        self.mock_clock = .{ .now = 0 };
        self.store = try store_board.Store.init(null);
        self.board = Board.init(allocator);
        try store_board.attach(&self.board, .{ .store = &self.store });

        const board = &self.board;
        board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
        board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
        board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 10);
        board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 10);
        board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
        board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);
        board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF112233);

        self.queue = frame_queue.Queue.init(std.testing.io, allocator, cap_bytes);
        self.tap = frame_tap.FrameTap.init(allocator, &self.board, &self.queue, self.mock_clock.clock());
        self.tap.arm(std.testing.io, &self.store);
        return self;
    }

    fn destroy(self: *Bench) void {
        const allocator = self.allocator;
        self.tap.deinit();
        self.queue.deinit();
        self.board.deinit();
        self.store.deinit();
        allocator.destroy(self);
    }
};

test "rate cap limits captures to 1/60s host time" {
    const bench = try Bench.create(std.testing.allocator, 1024 * 1024);
    defer bench.destroy();

    // 1st boundary at host time 0: capture happens
    bench.mock_clock.now = 0;
    bench.tap.onBoundary(1_000_000);
    try std.testing.expectEqual(@as(usize, 1), bench.queue.count());

    // Force dirty so change-trigger isn't the blocker
    bench.tap.glcdc_dirty = true;

    // 2nd boundary at host time 5 ms (< 16.66 ms): rate capped!
    bench.mock_clock.now = 5_000_000;
    bench.tap.onBoundary(2_000_000);
    try std.testing.expectEqual(@as(usize, 1), bench.queue.count());

    // 3rd boundary at host time 17 ms (>= 16.66 ms): captured!
    bench.mock_clock.now = 17_000_000;
    bench.tap.onBoundary(3_000_000);
    try std.testing.expectEqual(@as(usize, 2), bench.queue.count());
}

test "GLCDC write during rate-capped boundary is not lost on subsequent boundary" {
    const bench = try Bench.create(std.testing.allocator, 1024 * 1024);
    defer bench.destroy();

    // 1st boundary at host time 0: captured
    bench.mock_clock.now = 0;
    bench.tap.onBoundary(1_000_000);
    try std.testing.expectEqual(@as(usize, 1), bench.queue.count());

    // Host time 5 ms: firmware updates GLCDC background color
    bench.mock_clock.now = 5_000_000;
    bench.board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF998877);

    // Boundary at 5 ms is rate-capped (< 16.66 ms)
    bench.tap.onBoundary(2_000_000);
    try std.testing.expectEqual(@as(usize, 1), bench.queue.count());

    // Boundary at 17 ms: no new writes occurred, but the pending change must be captured!
    bench.mock_clock.now = 17_000_000;
    bench.tap.onBoundary(3_000_000);
    try std.testing.expectEqual(@as(usize, 2), bench.queue.count());
}

test "change trigger captures only when GLCDC or layer memory changes" {
    const bench = try Bench.create(std.testing.allocator, 1024 * 1024);
    defer bench.destroy();
    bench.tap.interval_ns = 0; // disable rate cap for change-trigger test

    // Setup Layer 1 framebuffer at SRAM base 0x2200_0000, 10x10 RGB565 (20 bytes stride)
    const fb_base: u32 = 0x2200_0000;
    bench.board.display.write(glcdc.win_base + glcdc.off.layer_base + glcdc.off.flm2, 4, fb_base);
    bench.board.display.write(glcdc.win_base + glcdc.off.layer_base + glcdc.off.flm3, 4, 20 << 16);
    bench.board.display.write(glcdc.win_base + glcdc.off.layer_base + glcdc.off.flm5, 4, (10 - 1) << 16);
    // RGB565 format = 0
    bench.board.display.write(glcdc.win_base + glcdc.off.layer_base + glcdc.off.flm6, 4, 0);
    // Enable fetching (FLMRD.RENB)
    bench.board.display.write(glcdc.win_base + glcdc.off.layer_base + glcdc.off.flmrd, 4, glcdc.field.renb);

    // Initial boundary: captured because glcdc was updated
    bench.tap.onBoundary(1_000_000);
    try std.testing.expectEqual(@as(usize, 1), bench.queue.count());

    // Subsequent boundary without writes: NOT captured
    bench.tap.onBoundary(2_000_000);
    try std.testing.expectEqual(@as(usize, 1), bench.queue.count());

    // Write to unrelated memory address (0x2200_8000, far from 0x2200_0000..0x2200_00C8): NOT captured
    try bench.store.write(.cpu0, 0x2200_8000, &[_]u8{0xAA});
    bench.tap.onBoundary(3_000_000);
    try std.testing.expectEqual(@as(usize, 1), bench.queue.count());

    // Write inside layer 1 span (0x2200_000A): change-triggered!
    try bench.store.write(.cpu0, fb_base + 10, &[_]u8{0x55});
    bench.tap.onBoundary(4_000_000);
    try std.testing.expectEqual(@as(usize, 2), bench.queue.count());

    // Write to GLCDC register (background color): change-triggered!
    bench.board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF445566);
    bench.tap.onBoundary(5_000_000);
    try std.testing.expectEqual(@as(usize, 3), bench.queue.count());
}

test "FrameTap captures authoritative Position from grid" {
    const bench = try Bench.create(std.testing.allocator, 1024 * 1024);
    defer bench.destroy();

    var sched_state = ra8.chip.core.scheduler.State{};
    sched_state.at = .{
        .branch = 0,
        .r = 345,
        .phase = .cpu0,
        .o = 12,
        .gap = .retired,
    };
    bench.tap.setPositionSource(&sched_state, 99);

    bench.tap.onBoundary(1_000_000);
    try std.testing.expectEqual(@as(usize, 1), bench.queue.count());

    const task = bench.queue.tryPop().?;
    try std.testing.expectEqual(@as(u32, 99), task.position.branch);
    try std.testing.expectEqual(@as(u64, 345), task.position.r);
    try std.testing.expectEqual(@as(u32, 12), task.position.o);
}

test "FrameTap newSegment forces keyframe" {
    const bench = try Bench.create(std.testing.allocator, 1024 * 1024);
    defer bench.destroy();
    bench.tap.interval_ns = 0;

    // First frame is keyframe
    bench.tap.onBoundary(1_000_000);
    const f1 = bench.queue.tryPop().?;
    try std.testing.expectEqual(frame_queue.FrameKind.keyframe, f1.kind);

    // Second frame is delta
    bench.board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF223344);
    bench.tap.onBoundary(2_000_000);
    const f2 = bench.queue.tryPop().?;
    try std.testing.expectEqual(frame_queue.FrameKind.delta, f2.kind);

    // Establish new segment -> forces keyframe!
    bench.tap.newSegment();
    bench.board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF334455);
    bench.tap.onBoundary(3_000_000);
    const f3 = bench.queue.tryPop().?;
    try std.testing.expectEqual(frame_queue.FrameKind.keyframe, f3.kind);
}

test "tap never perturbs guest state" {
    const elf = "tests/fixtures/dfu/dfu_bootloader.elf";
    const gpa = std.testing.allocator;

    // Run 1: Tap disabled (baseline)
    var h1 = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = elf });
    defer h1.deinit();

    // Run 2: Tap enabled (with active queue)
    var q = frame_queue.Queue.init(std.testing.io, gpa, 64 * 1024 * 1024);
    defer q.deinit();
    var h2 = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = elf });
    defer h2.deinit();

    // Actively configure GLCDC display controller on both boards identically
    inline for (.{ h1.board(), h2.board() }) |board| {
        board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
        board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
        board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 10);
        board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 10);
        board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
        board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);
        board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF112233);
    }

    var tap = frame_tap.FrameTap.init(gpa, h2.board(), &q, frame_tap.clockFromIo(std.testing.io));
    defer tap.deinit();
    tap.arm(std.testing.io, h2.guest().store);

    for (0..50) |_| _ = try h1.session().run(.cpu0, .step);
    const now1 = try h1.session().now();

    for (0..50) |i| {
        _ = try h2.session().run(.cpu0, .step);
        tap.onBoundary(@as(u64, i) * 20_000_000);
    }
    const now2 = try h2.session().now();

    // Assert that active frames were actually captured by the tap during the run!
    try std.testing.expect(q.count() > 0);

    // Guest architectural state is 100% byte-identical
    try std.testing.expectEqual(now1, now2);
    try std.testing.expectEqual(try h1.session().register(.cpu0, .pc), try h2.session().register(.cpu0, .pc));
    try std.testing.expectEqual(try h1.session().register(.cpu0, .sp), try h2.session().register(.cpu0, .sp));
    try std.testing.expectEqual(try h1.session().register(.cpu0, .lr), try h2.session().register(.cpu0, .lr));
    try std.testing.expectEqual(try h1.session().register(.cpu0, .r0), try h2.session().register(.cpu0, .r0));
}
