//! Covers src/interfaces/cli/window_run.zig: a Zig-core run shown in a
//! headless window advances one frame per tick, ends the loop when the run
//! ends, and ends the run when the window closes.
const std = @import("std");
const ra8 = @import("ra8");
const store_board = @import("store_board.zig");
const soaker = @import("soaker.zig");

const zig_run = ra8.board.zig_run;
const cpu_boot = ra8.core.cpu.boot;
const window_run = ra8.board.window_run;
const Pacer = ra8.board.window_pace.Pacer;
const Headless = ra8.gui.headless.Headless;

const per_frame: u64 = 20_000;

/// A soaker image on the Zig core with a paced clock.
const Soak = struct {
    store: store_board.Store,
    board: ra8.board.Board,
    timebase: ra8.periph.clocks.Clocks = .{ .per_chunk = 5_000 },
    pacer: Pacer = .{ .per_frame = per_frame },
    clock: zig_run.Clock = undefined,
    budget: u64,
    ran: u64 = 0,
    failed: bool = false,

    fn init(self: *Soak, budget: u64) !void {
        self.* = .{ .store = try store_board.Store.init(null), .board = ra8.board.Board.init(std.testing.allocator), .budget = budget };
        const core = self.guest();
        try soaker.load(core, false);
        try store_board.attach(&self.board, core);
        self.clock = .{ .memory = core, .board = &self.board, .timebase = &self.timebase, .pace = &self.pacer };
    }

    fn deinit(self: *Soak) void {
        self.board.deinit();
        self.store.deinit();
    }

    fn guest(self: *Soak) store_board.Guest {
        return .{ .store = &self.store };
    }

    fn engine(self: *Soak) window_run.Engine {
        return .{ .ctx = self, .run = run };
    }

    fn run(ctx: *anyopaque) void {
        const self: *Soak = @ptrCast(@alignCast(ctx));
        var final: cpu_boot.Regs = .{};
        var output: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&output);
        _ = cpu_boot.start(stream.writer(), .zig, self.guest(), &self.board.bus, soaker.base, self.budget, &self.ran, .{ .boundary = self.clock.boundary(), .final = &final }) catch {
            self.failed = true;
        };
    }
};

test "the window draws a frame per slice until the run ends" {
    var soak: Soak = undefined;
    try soak.init(100_000);
    defer soak.deinit();
    var window = Headless.init(std.testing.allocator, 1280, 700);
    defer window.deinit();
    const shown = try window_run.show(std.testing.allocator, window.platform(), &soak.board, &soak.pacer, soak.engine());
    try std.testing.expect(!soak.failed);
    try std.testing.expect(!shown.closed);
    try std.testing.expect(shown.frames >= 4);
    // The tick on which the run ends still draws, so the window is left
    // showing the board as the run left it.
    try std.testing.expectEqual(shown.frames + 1, window.presents);
    // The soaker sleeps, so board time, not retired instructions, is what
    // each frame's grant buys.
    try std.testing.expect(soak.board.time.base.now() >= shown.frames * per_frame);
}

test "closing the window ends the run at its next boundary" {
    var soak: Soak = undefined;
    try soak.init(1_000_000_000);
    defer soak.deinit();
    var window = Headless.init(std.testing.allocator, 1280, 700);
    defer window.deinit();
    try window.feed(.quit);
    const shown = try window_run.show(std.testing.allocator, window.platform(), &soak.board, &soak.pacer, soak.engine());
    try std.testing.expect(!soak.failed);
    try std.testing.expect(shown.closed);
    try std.testing.expectEqual(@as(u32, 0), shown.frames);
    try std.testing.expectEqual(@as(u32, 0), window.presents);
    try std.testing.expect(soak.board.time.base.now() <= per_frame);
    try std.testing.expect(soak.clock.paced_out);
}
