//! Covers the host window's pacer on src/interfaces/cli/zig_run.zig's
//! Clock (RA8EMU-646): a Zig-core run on its own thread advances one frame
//! per window step and ends when the window closes.
const std = @import("std");
const ra8 = @import("ra8");
const store_board = @import("store_board.zig");
const soaker = @import("soaker.zig");

const zig_run = ra8.board.zig_run;
const cpu_boot = ra8.core.cpu.boot;
const Pacer = ra8.board.window_pace.Pacer;

const budget: u64 = 50_000_000;

test "a window that has closed ends the run at the next boundary" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    var timebase: ra8.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var pacer = Pacer{ .per_frame = 20, .io = std.testing.io_000 };
    pacer.stop();
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .pace = &pacer };
    try std.testing.expect(!clock.done());
    try clock.close(100);
    try std.testing.expect(clock.paced_out);
    try std.testing.expect(clock.done());
}

const Paced = struct {
    core: store_board.Guest,
    board: *ra8.board.Board,
    clock: *zig_run.Clock,
    pacer: *Pacer,
    ran: u64 = 0,
    failed: bool = false,

    fn run(self: *Paced) void {
        defer self.pacer.finish();
        var final: cpu_boot.Regs = .{};
        var output: [1024]u8 = undefined;
        var stream: std.Io.Writer = .fixed(&output);
        _ = cpu_boot.start(&stream, .zig, self.core, &self.board.bus, soaker.base, budget, &self.ran, .{ .boundary = self.clock.boundary(), .final = &final }) catch {
            self.failed = true;
        };
    }
};

test "a Zig-core run moves one frame per window step and stops when it closes" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    try soaker.load(core, false);
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    var timebase: ra8.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var pacer = Pacer{ .per_frame = 20, .io = std.testing.io_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .pace = &pacer };
    var paced = Paced{ .core = core, .board = &board, .clock = &clock, .pacer = &pacer };
    const thread = try std.Thread.spawn(.{}, Paced.run, .{&paced});
    var seen: [3]u64 = undefined;
    for (&seen) |*ticks| {
        try std.testing.expect(pacer.step());
        ticks.* = board.time.base.now();
    }
    try std.testing.expect(seen[0] > 0 and seen[1] > seen[0] and seen[2] > seen[1]);
    pacer.stop();
    thread.join();
    try std.testing.expect(!paced.failed);
    try std.testing.expect(clock.paced_out);
    try std.testing.expect(paced.ran < budget);
    try std.testing.expect(!pacer.step());
}
