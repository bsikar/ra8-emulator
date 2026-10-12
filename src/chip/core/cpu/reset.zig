//! Reset from the vector table: what the processor does before its first
//! instruction. Word 0 is the initial Main stack pointer and word 1 is the
//! reset handler, whose bit 0 becomes EPSR.T.
const bus = @import("bus.zig");
const regs_mod = @import("regs.zig");
pub const scs = @import("exception/reset_scs.zig");
const Cpu = @import("cpu.zig").Cpu;

/// LR after reset. All ones is an illegal exception return, so a reset
/// handler that returns faults instead of running off into memory.
pub const lr_at_reset: u32 = 0xFFFF_FFFF;

pub fn fromVectorTable(regs: *regs_mod.Regs, from: bus.Bus, vtor: u32) bus.Error!void {
    const initial_sp = try from.readWord(vtor);
    const handler = try from.readWord(vtor +% 4);
    regs.* = .{};
    regs.setMsp(initial_sp & ~@as(u32, 3));
    regs.lr = lr_at_reset;
    regs.pc = handler & ~@as(u32, 1);
    if (handler & 1 != 0) regs.xpsr = regs_mod.xpsr_bits.thumb;
}

/// Warm and initial reset share architectural defaults, while cumulative
/// execution counters and embedding hooks retain their identity. The first
/// reset of a core is its power-on: the SCS words the board or a fixture
/// seeded before it are that boot's configuration and stay. Every later one
/// is a reboot, and clears what the guest left in both banks, however little
/// ran in between.
pub fn cpu(core: *Cpu, vtor: u32) bus.Error!void {
    var fresh: regs_mod.Regs = .{};
    try fromVectorTable(&fresh, core.bus, vtor);
    core.trip.drop(core);
    core.banked = .{};
    if (core.booted) try scs.clear(core.bus);
    core.booted = true;
    core.regs = fresh;
    core.fp = .{};
    core.exclusive = null;
    core.entering_non_secure = false;
    core.secure_faults = 0;
    core.vtor = vtor;
    core.raised = null;
    core.active = .{};
    core.event = false;
    core.waiting = null;
    core.trip = .{};
    if (core.quiet) |q| q.stirAll();
    if (core.cut) |edge| _ = edge.take();
    if (core.blocks) |cache| cache.init();
}
