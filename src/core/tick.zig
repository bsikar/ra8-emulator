//! Something for the engine to run at a chunk boundary.
//!
//! A thin vtable rather than a concrete type, for the same reason the
//! peripheral bus takes one: the engine has no business knowing what a
//! board is made of. The board hands one in; the engine only calls it.
const engine = @import("engine.zig");

pub const Tick = struct {
    context: *anyopaque,
    tickFn: *const fn (context: *anyopaque, core: engine.Engine, instructions: u32) anyerror!void,

    pub fn run(self: Tick, core: engine.Engine, instructions: u32) !void {
        return self.tickFn(self.context, core, instructions);
    }
};
