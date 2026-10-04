//! Something for the run loop to run at a chunk boundary.
//!
//! A thin vtable rather than a concrete type, for the same reason the
//! peripheral bus takes one: the run loop has no business knowing what a
//! board is made of. The board hands one in; the run loop only calls it.
const Guest = @import("cpu/memory/guest.zig").Guest;

pub const Tick = struct {
    context: *anyopaque,
    tickFn: *const fn (context: *anyopaque, core: Guest, instructions: u32) anyerror!void,
    /// Cycles until the board's next queued event (RA8EMU-575), zero when
    /// nothing is queued. Null for a tick with no queue to ask.
    dueFn: ?*const fn (context: *anyopaque) u64 = null,

    /// `core` is a Guest, or the engine, which is wrapped into one until
    /// the engine goes (RA8EMU-482).
    pub fn run(self: Tick, core: anytype, instructions: u32) !void {
        const guest: Guest = if (@TypeOf(core) == Guest) core else .{ .engine = core };
        return self.tickFn(self.context, guest, instructions);
    }

    pub fn cyclesToDue(self: Tick) u64 {
        const due = self.dueFn orelse return 0;
        return due(self.context);
    }
};
