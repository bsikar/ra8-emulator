//! Where the `--dump-regs` rows of `--report json` read from (RA8EMU-579):
//! the Unicorn engine on a Unicorn run, or the Zig core's registers as a
//! `--cpu zig` run left them. Before this a Zig run read the engine, which
//! still held the reset values.
const engine = @import("../../../core/engine.zig");
const Regs = @import("../../../core/cpu/regs.zig").Regs;

pub const Reader = union(enum) {
    engine: engine.Engine,
    zig: *const Regs,

    /// The register's value, or null when its source will not give it.
    pub fn register(self: Reader, which: engine.Cortex) ?u32 {
        return switch (self) {
            .engine => |core| core.register(which) catch null,
            .zig => |regs| fromRegs(regs, which),
        };
    }
};

/// The dumped registers out of the Zig core's file. SP is the active
/// stack pointer, the one the core's R13 names right now.
fn fromRegs(regs: *const Regs, which: engine.Cortex) ?u32 {
    return switch (which) {
        .r0 => regs.get(0),
        .r1 => regs.get(1),
        .r2 => regs.get(2),
        .r3 => regs.get(3),
        .r4 => regs.get(4),
        .r5 => regs.get(5),
        .r6 => regs.get(6),
        .r7 => regs.get(7),
        .r8 => regs.get(8),
        .r9 => regs.get(9),
        .r10 => regs.get(10),
        .r11 => regs.get(11),
        .r12 => regs.get(12),
        .sp => regs.get(13),
        .lr => regs.lr,
        .pc => regs.pc,
        else => null,
    };
}
