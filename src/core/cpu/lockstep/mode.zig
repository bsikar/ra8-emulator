//! `--cpu lockstep`: the image runs on Unicorn and the Zig core side by side,
//! and the run ends with how it stopped and the per-class divergence table.
//!
//! The Zig core gets an engine of its own holding the same image, so the two
//! never read each other's stores. Peripherals stay on Unicorn's side: it
//! steps first and owns their side effects, a tap logs what it did, and the
//! Zig core's peripheral accesses are replayed from and checked against that
//! log (periph_log.zig, replay_bus.zig).
const std = @import("std");
const engine = @import("../../engine.zig");
const seed = @import("seed.zig");
const elf = @import("../../elf.zig");
const cpu_mod = @import("../cpu.zig");
const ReplayBus = @import("replay_bus.zig").ReplayBus;
const periph_log = @import("periph_log.zig");
const tap_hook = @import("tap_hook.zig");
const snapshot = @import("snapshot.zig");
const oracle = @import("oracle.zig");
const run_mod = @import("run.zig");
const sau = @import("../../../periph/sau.zig");
const mpu = @import("../../../periph/mpu/mpu.zig");
const fault_clear = @import("../../../periph/fault_clear.zig");
const report = @import("report.zig");
const Cpu1 = @import("dual.zig").Cpu1;
const RetireListener = cpu_mod.RetireListener;

/// The images a lockstep run loads: the main one and, for a TrustZone
/// pair, its Non-Secure half at its load address.
pub const Images = struct {
    main: elf.Image,
    ns: ?elf.Image = null,
};

/// `theirs` is the engine the caller already loaded and reset.
pub fn run(out: anytype, images: Images, theirs: *const engine.Engine, vector_base: u32, budget: u64, settle: ?*fault_clear.Clears, cpu1: ?*Cpu1, retire_listener: ?RetireListener) !u8 {
    var mine = try engine.Engine.open();
    defer mine.close();
    try mine.mapBoardRam();
    _ = try mine.loadImage(images.main);
    if (images.ns) |half| _ = try mine.loadImage(half);
    if (cpu1) |side| try side.attach(&mine);
    return runLoaded(out, &mine, theirs.*, vector_base, budget, settle, cpu1, retire_listener);
}

/// Both engines already hold the image. Returns 0 when the budget was spent
/// with no divergence, 1 otherwise.
/// `settle` is the oracle's fault-clear latch; with one, both sides clear
/// CFSR/HFSR/SFSR within the storing instruction.
pub fn runLoaded(out: anytype, mine: *const engine.Engine, theirs: engine.Engine, vector_base: u32, budget: u64, settle: ?*fault_clear.Clears, cpu1: ?*Cpu1, retire_listener: ?RetireListener) !u8 {
    var log: periph_log.Log = .{};
    var partitions = sau.Sau.init();
    var regions = mpu.Mpu.init();
    var clears = fault_clear.Clears.init();
    const own_clears: ?*fault_clear.Clears = if (settle != null) &clears else null;
    var memory: ReplayBus = .{ .memory = .{ .core = mine }, .log = &log, .scs = .{ .partitions = &partitions, .regions = &regions, .clears = own_clears } };
    var cpu: cpu_mod.Cpu = .{ .bus = memory.view(), .retire_listener = retire_listener };
    // The oracle's board wiring may have set PPB state (DWT_CTRL.NUMCOMP)
    // the image alone does not carry.
    _ = seed.ppb(mine.*, theirs);
    cpu.reset(vector_base) catch {
        try out.print("lockstep: no vector table at 0x{X:0>8}\n", .{vector_base});
        return 1;
    };
    // Both start from the Zig core's reset state, so a difference in how
    // each comes out of reset is not counted against the first instruction.
    try oracle.load(theirs, snapshot.Snapshot.fromRegs(&cpu.regs));
    const taps = try tap_hook.attach(theirs.handle, &log);
    defer tap_hook.detach(theirs.handle, taps);
    const gpa = std.heap.page_allocator;
    var lock: run_mod.Run = .{ .settle = settle, .between = if (cpu1) |side| side.between() else null };
    defer lock.deinit(gpa);
    const ended = try lock.go(gpa, &cpu, theirs, &log, budget);
    try report.write(out, &lock, ended);
    try out.print("lockstep: {d} peripheral access(es) replayed and matched\n", .{log.matched});
    try lock.counts.writeTable(out);
    if (cpu1) |side| try side.write(out);
    const cpu1_clean = if (cpu1) |side| side.clean() else true;
    return if (ended == .budget and cpu1_clean) 0 else 1;
}
