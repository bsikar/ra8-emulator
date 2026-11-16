//! Scheduler boundaries, snapshot edges, and warm reboot during a core run.
const boot = @import("boot.zig");
const cpu_mod = @import("cpu.zig");

const Boundary = boot.Boundary;
const Snapshot = boot.Snapshot;
const Owed = boot.Owed;
const Reboot = @import("../reboot.zig").Reboot;
const scheduler = @import("../scheduler/scheduler.zig");
const Until = @import("../until.zig").Until;

/// The budget in stretches, each closed by the boundary. A stretch the core
/// stops inside is not closed: it never ran to its edge. `owed` carries a
/// stretch across a save and a load (RA8EMU-700).
pub fn stretches(
    cpu: *cpu_mod.Cpu,
    budget: u64,
    boundary: ?Boundary,
    until: ?*Until,
    owed: *Owed,
    snapshot: ?Snapshot,
) !cpu_mod.Stop {
    _ = until;
    const edge = boundary orelse return cpu.run(budget);
    if (cpu.cut) |latch| latch.instruction = &cpu.slots;
    var local: scheduler.State = .{};
    const saved = edge.saved orelse &local;
    if (saved.stretch.full == 0) saved.stretch.carry = owed.in;
    owed.out = 0;
    var left = budget;
    while (left > 0) {
        // A loaded run can begin after CPU0 already finished this interval.
        if (saved.cut or saved.at.phase != .cpu0) {
            if (saved.at.phase == .cpu0) saved.endCpu0(true, false);
            if (saved.at.phase == .cpu1) saved.endCpu0(false, false);
            if (try closeBoundary(cpu, edge, saved, snapshot)) return .count;
            continue;
        }
        if (saved.stretch.full == 0) saved.open(widthOf(cpu, edge), cpu.slots);
        const progress = advance(cpu, saved, left);
        left -= progress.elapsed;
        const stopped = progress.stopped;
        const cut = progress.cut;
        if (stopped != .count or (!cut and saved.stretch.carry < saved.stretch.full)) {
            owed.out = saved.stretch.carry;
            return stopped;
        }
        saved.endCpu0(cut, false);
        if (try closeBoundary(cpu, edge, saved, snapshot)) return .count;
    }
    return .count;
}

/// A `--snapshot-at` write, once its time has come (RA8EMU-769).
fn midway(hook: Snapshot, cpu: *const cpu_mod.Cpu) !void {
    const due = hook.dueFn orelse return;
    const write = hook.atFn orelse return;
    if (due(hook.context)) try write(hook.context, cpu);
}

/// The next stretch's width: the boundary's, reached to the next edge by
/// its `sleepFn` while the core sleeps with nothing to wake it.
fn widthOf(cpu: *cpu_mod.Cpu, edge: Boundary) u32 {
    _ = cpu;
    const normal = @max(1, edge.widthFn(edge.context));
    const reach = edge.sleepFn orelse return normal;
    return @max(normal, reach(edge.context, normal));
}

/// A warm reboot of the Zig core: SP and PC from the vector table, PRIMASK clear, handler frames
/// abandoned, RAM kept. The retired count is the run's, so it carries on.
fn rebooted(cpu: *cpu_mod.Cpu, pending: *Reboot) !void {
    pending.requested = false;
    pending.performed +%= 1;
    const retired = cpu.retired;
    try cpu.reset(pending.vector_base);
    cpu.retired = retired;
}

/// Charge the board, advance the scheduler, then process stop/reboot/snapshot hooks.
fn closeBoundary(cpu: *cpu_mod.Cpu, edge: Boundary, saved: *scheduler.State, snapshot: ?Snapshot) !bool {
    try edge.closeFn(edge.context, saved.stretch.carry);
    saved.next();
    if (edge.doneFn) |done| if (done(edge.context)) return true;
    if (edge.reboot) |pending| if (pending.requested) try rebooted(cpu, pending);
    if (snapshot) |hook| try midway(hook, cpu);
    return false;
}

const Progress = struct { elapsed: u64, stopped: cpu_mod.Stop, cut: bool };

fn advance(cpu: *cpu_mod.Cpu, saved: *scheduler.State, left: u64) Progress {
    const width: u32 = @intCast(@min(left, saved.stretch.left()));
    const before = cpu.slots;
    const stopped = cpu.runToCount(width, cpu.slots + width);
    const ran: u32 = @intCast(cpu.slots - before);
    // A sleeping core can consume the interval without executing every slot.
    const elapsed = if (stopped == .count and cpu.waiting != null) width else ran;
    saved.advance(elapsed, ran);
    const cut_pending = if (cpu.cut) |latch| latch.takePending() else null;
    const cut = cut_pending != null;
    saved.cut = cut;
    saved.cut_pending = cut_pending orelse .{};
    return .{ .elapsed = elapsed, .stopped = stopped, .cut = cut };
}
