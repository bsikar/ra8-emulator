//! Architectural slot budgets and absolute canonical count stops.
const cpu_mod = @import("cpu.zig");
const exception = @import("exception/all.zig");
const park = @import("park.zig");

pub fn run(cpu: *cpu_mod.Cpu, count: u64, target: ?u64) cpu_mod.Stop {
    if (cpu.quiet) |q| q.stir();
    defer cpu.trip.drop(cpu);
    var left = count;
    cpu.trip.parked = false;
    while (left > 0) {
        const lent = cpu.trip.lend(cpu);
        const taken = exception.dispatch.poll(cpu) catch return .{ .bus_fault = cpu.regs.pc };
        cpu.trip.reclaim(cpu, lent, taken);
        if (taken) cpu.waiting = null;
        if (cpu.waiting) |why| {
            const up = exception.sleep.wakes(cpu, why) catch return .{ .bus_fault = cpu.regs.pc };
            if (!up) return .count;
            cpu.waiting = null;
        }
        // Poll entries and wake consumption belong to the gap, never a slot.
        if (target) |at| if (cpu.slots >= at) return .count;
        if (cpu.fetch_guard) |guard| if (guard.holds(cpu.regs.pc)) return .count;
        const budget = if (target) |at| @min(left, at - cpu.slots) else left;
        const skipped = if (cpu.fetch_guard == null) park.trips(cpu, budget) else 0;
        if (skipped != 0) {
            cpu.retired += skipped;
            cpu.slots += skipped;
            left -= skipped;
            continue;
        }
        if (cpu.step()) |stopped| return stopped;
        left -= 1;
        if (cpu.until) |wait| if (wait.met()) return .count;
        if (cpu.cut) |edge| if (edge.fired) return .count;
    }
    return .count;
}
