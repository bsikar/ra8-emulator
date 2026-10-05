//! The board's chunk boundary under the debugger (RA8EMU-709). A plain run
//! passes the boundary every chunk, which is where board time advances,
//! timed blocks raise their events and the pacer holds wall time. The
//! debugger owns its own loop, so without this nothing past the core moved
//! while a script ran. Here the session's run is cut into chunks and the
//! board is ticked by what each chunk retired, including a chunk a stop cut
//! short, so board time always equals instructions run.
const zig_core = @import("zig_core.zig");
const zig_cycles = @import("zig_cycles.zig");
const zig_drive = @import("zig_drive.zig");
const stop_machine = @import("stop_machine.zig");
const watch_bus = @import("watch_bus.zig");

/// Instructions between boundaries when the board names none.
pub const default_chunk: u32 = 1024;

pub const Error = error{BoundaryFailed};

/// What the board offers: advance by `instructions` retired.
pub const Boundary = struct {
    context: *anyopaque,
    tickFn: *const fn (context: *anyopaque, instructions: u32) anyerror!void,
    chunk: u32 = default_chunk,

    fn tick(self: Boundary, instructions: u64) Error!void {
        if (instructions == 0) return;
        self.tickFn(self.context, @intCast(instructions)) catch return Error.BoundaryFailed;
    }
};

/// As zig_drive.runClocked, passing `edge` after every chunk.
pub fn run(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64, watch: ?*watch_bus.WatchBus, clock: ?*zig_cycles.Clock, edge: Boundary) Error!zig_drive.Ended {
    const width: u64 = @max(edge.chunk, 1);
    var left = count;
    while (left > 0) {
        const want = @min(left, width);
        var retired: u64 = 0;
        const ended = zig_drive.runCounted(core, machine, want, watch, clock, &retired);
        try edge.tick(retired);
        switch (ended) {
            .count => left -= want,
            else => return ended,
        }
    }
    return .count;
}
