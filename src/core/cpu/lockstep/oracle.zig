//! The Unicorn side of a lockstep run: its registers read into a Snapshot,
//! and a Snapshot written back so both backends start from the same state.
//!
//! Each compared name maps to the engine's register of the same name at
//! compile time, so a name the engine stops exposing fails the build rather
//! than a run.
const engine = @import("../../engine.zig");
const regs = @import("../regs.zig");
const snapshot = @import("snapshot.zig");

fn cortexFor(comptime name: regs.Name) engine.Cortex {
    return @field(engine.Cortex, @tagName(name));
}

pub fn read(core: engine.Engine) engine.Error!snapshot.Snapshot {
    var values: [snapshot.compared.len]u32 = undefined;
    inline for (snapshot.compared, 0..) |name, i| {
        values[i] = try core.register(cortexFor(name));
    }
    return .{ .values = values };
}

/// Write every compared register. CONTROL goes before the stack pointers so
/// the banked pointer each write lands on is already the selected one.
pub fn load(core: engine.Engine, state: snapshot.Snapshot) engine.Error!void {
    try core.setRegister(.control, state.get(.control).?);
    inline for (snapshot.compared, 0..) |name, i| {
        if (name != .control) try core.setRegister(cortexFor(name), state.values[i]);
    }
}
