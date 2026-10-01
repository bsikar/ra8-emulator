//! `--cpu lockstep`: the image runs on Unicorn and the Zig core side by side,
//! and the run ends with how it stopped and the per-class divergence table.
//!
//! The Zig core gets an engine of its own holding the same image, so the two
//! never read each other's stores. That engine has no peripherals on it, so a
//! peripheral access by the Zig core stops the run as a bus fault for now.
const std = @import("std");
const engine = @import("../../engine.zig");
const elf = @import("../../elf.zig");
const cpu_mod = @import("../cpu.zig");
const EngineBus = @import("../engine_bus.zig").EngineBus;
const snapshot = @import("snapshot.zig");
const oracle = @import("oracle.zig");
const run_mod = @import("run.zig");
const report = @import("report.zig");

/// `theirs` is the engine the caller already loaded and reset.
pub fn run(out: anytype, image: elf.Image, theirs: *const engine.Engine, vector_base: u32, budget: u64) !u8 {
    var mine = try engine.Engine.open();
    defer mine.close();
    try mine.mapBoardRam();
    _ = try mine.loadImage(image);
    return runLoaded(out, &mine, theirs.*, vector_base, budget);
}

/// Both engines already hold the image. Returns 0 when the budget was spent
/// with no divergence, 1 otherwise.
pub fn runLoaded(out: anytype, mine: *const engine.Engine, theirs: engine.Engine, vector_base: u32, budget: u64) !u8 {
    var memory: EngineBus = .{ .core = mine };
    var cpu: cpu_mod.Cpu = .{ .bus = memory.view() };
    cpu.reset(vector_base) catch {
        try out.print("lockstep: no vector table at 0x{X:0>8}\n", .{vector_base});
        return 1;
    };
    // Both start from the Zig core's reset state, so a difference in how
    // each comes out of reset is not counted against the first instruction.
    try oracle.load(theirs, snapshot.Snapshot.fromRegs(&cpu.regs));
    const gpa = std.heap.page_allocator;
    var lock: run_mod.Run = .{};
    defer lock.deinit(gpa);
    const ended = try lock.go(gpa, &cpu, theirs, budget);
    try report.write(out, &lock, ended);
    try lock.counts.writeTable(out);
    return if (ended == .budget) 0 else 1;
}
