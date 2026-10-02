//! A `--cpu zig` (or `--cpu lockstep`) run started from main, with the
//! board's time wired in. The Unicorn run loop charges SysTick, DWT_CYCCNT
//! and the blocks at every chunk boundary; this gives the Zig core the same
//! boundary, so a ThreadX image gets its tick and the peripherals that count
//! time (the USB host script among them) move.
const std = @import("std");
const engine = @import("../../core/engine.zig");
const boot = @import("../../core/cpu/boot.zig");
const elf = @import("../../core/elf.zig");
const clocks = @import("../../periph/clocks.zig");
const cli = @import("cli.zig");
const Board = @import("../../board/board.zig").Board;
const report_run = @import("report_run.zig");

/// The board side of a Zig-core boundary.
pub const Clock = struct {
    core: *engine.Engine,
    board: *Board,
    timebase: *clocks.Clocks,

    pub fn boundary(self: *Clock) boot.Boundary {
        return .{ .context = self, .widthFn = widthThunk, .closeFn = closeThunk };
    }

    /// The chunk the Unicorn path uses, cut down to the armed SysTick period
    /// so a stretch never swallows more than one wrap.
    pub fn width(self: *const Clock) u32 {
        const period = self.timebase.period(self.core.*);
        if (period != 0 and period < self.timebase.per_chunk) return period;
        return self.timebase.per_chunk;
    }

    /// Charge the stretch to the clocks, then tick the blocks, in the order
    /// the Unicorn run loop does.
    pub fn close(self: *Clock, instructions: u32) !void {
        try self.timebase.advance(self.core.*, instructions);
        try self.board.tick(self.core.*);
    }
};

fn widthThunk(context: *anyopaque) u32 {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.width();
}

fn closeThunk(context: *anyopaque, instructions: u32) anyerror!void {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.close(instructions);
}

/// Run off Unicorn, then, for a Zig run, print what the board has to say.
pub fn run(out: std.fs.File.Writer, core: *engine.Engine, board: *Board, timebase: *clocks.Clocks, image: elf.Image, options: cli.Options, vector_base: u32) !u8 {
    var ran: u64 = 0;
    var clock: Clock = .{ .core = core, .board = board, .timebase = timebase };
    const status = try boot.start(out, options.cpu, image, core, &board.bus, vector_base, options.budgetFor(false), &ran, .{ .boundary = clock.boundary(), .partitions = &board.partitions, .regions = &board.regions });
    if (options.cpu == .zig) try report_run.zigCore(out, board, ran);
    return status;
}
