//! The stop machine fed from the Zig core (RA8EMU-105). The machine wants the machine each instruction before it
//! runs; here the debugger owns the loop, so it builds the same event,
//! asks the machine, and only then lets the core execute.
const std = @import("std");
const zig_core = @import("core.zig");
const stop_machine = @import("../stop_machine.zig");
const call_decode = @import("../call_decode.zig");
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const watch_bus = @import("../watch/bus.zig");
const zig_cycles = @import("cycles.zig");
/// Re-exported for tests/session/zig/monitor_test.zig.
pub const zig_monitor = @import("monitor.zig");

/// How a driven run ended.
pub const Ended = union(enum) {
    /// The machine stopped the core before the instruction at the PC ran.
    stop: stop_machine.Stop,
    /// Every instruction allowed ran without a stop.
    count,
    /// The core itself stopped (an unknown encoding, a bus fault, ...).
    core: cpu_mod.Stop,
};

/// The event for the instruction under the PC: its address and width, SP before it runs, and whether it is a call.
pub fn event(core: zig_core.ZigCore) stop_machine.Event {
    const pc = core.register(.pc);
    const sp = core.register(.sp);
    var bytes: [4]u8 = .{ 0, 0, 0, 0 };
    core.read(pc, bytes[0..2]) catch return .{ .pc = pc, .size = 2, .sp = sp };
    const width: u8 = if (wide(bytes[0..2].*)) 4 else 2;
    if (width == 4) core.read(pc +% 2, bytes[2..4]) catch {};
    return .{ .pc = pc, .size = width, .sp = sp, .call = call_decode.isCall(bytes[0..width]) };
}

/// A first halfword whose top five bits are 0b11101, 0b11110 or 0b11111
/// starts a 32-bit Thumb instruction.
fn wide(first: [2]u8) bool {
    return std.mem.readInt(u16, &first, .little) >> 11 >= 0b11101;
}

/// Run up to `count` instructions under the machine's current mode. A
/// pending exception is taken first, so the event describes the
/// instruction that is really about to run.
pub fn run(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64) Ended {
    return runWatched(core, machine, count, null);
}

/// As `run`, with `watch` listening to the loads and stores each
/// instruction makes (RA8EMU-113). It listens only while the instruction runs, so neither the
/// debugger's own reads nor the instruction's fetch count as an access.
pub fn runWatched(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64, watch: ?*watch_bus.WatchBus) Ended {
    return runClocked(core, machine, count, watch, null);
}

/// As `runWatched`, with a non-writing projection for DWT cycle comparators.
pub fn runClocked(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64, watch: ?*watch_bus.WatchBus, clock: ?*zig_cycles.Clock) Ended {
    var retired: u64 = 0;
    return runCounted(core, machine, count, watch, clock, &retired);
}

/// As `runClocked`, adding architectural slots to the legacy-named output.
/// The scheduler accounts for sleep tails separately as elapsed time.
pub fn runCounted(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64, watch: ?*watch_bus.WatchBus, clock: ?*zig_cycles.Clock, retired: *u64) Ended {
    return runTarget(core, machine, count, watch, clock, retired, null);
}

/// Stop at a canonical per-core slot count after polling and waking, before
/// the next instruction. A phase-end target is checked in the next phase.
pub fn runTarget(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64, watch: ?*watch_bus.WatchBus, clock: ?*zig_cycles.Clock, retired: *u64, target: ?u64) Ended {
    // The board moved, or the debugger wrote state, since the last chunk:
    // the poll asks the source afresh before trusting a hush again.
    if (core.cpu.quiet) |hushing| hushing.stirAll();
    var left = if (target != null and target.? <= core.cpu.slots) @max(count, 1) else count;
    while (left > 0) {
        // Nothing armed: run as a plain run does. The watch bus stays armed
        // so firmware that programs the FPB or DWT still reaches them.
        if (machine.quiet()) {
            if (clock) |counting| counting.tick(core, machine);
            const went = quietRun(core, watch, left, target);
            retired.* += went.ran;
            left -= went.ran;
            if (went.stop) |stopped| return .{ .core = stopped };
            if (went.ran == 0 or core.cpu.waiting != null) return .count;
            if (target) |at| if (core.cpu.slots >= at) return .count;
            if (core.cpu.cut) |cut| if (cut.fired) return .count;
            continue;
        }
        if (!machine.resumed and (machine.watch_pending != null or machine.unit_pending != null or machine.halt_pending)) {
            const stop = machine.onInstruction(event(core));
            zig_monitor.take(core, machine);
            if (stop) |why| {
                if (clock) |counting| counting.halted(core, machine, why);
                return .{ .stop = why };
            }
        }
        const pc = core.cpu.regs.pc;
        const polled = core.cpu.runToCount(1, core.cpu.slots);
        if (polled != .count) return .{ .core = polled };
        if (core.cpu.waiting != null) return .count;
        if (target) |at| if (core.cpu.slots >= at) return .count;
        if (core.cpu.fetch_guard) |guard| if (guard.holds(core.cpu.regs.pc)) return .count;
        if (clock) |counting| counting.tick(core, machine);
        const now = event(core);
        // The poll entered an exception: the resume grace belongs to the old
        // PC, and a step ends here, before the handler's first instruction.
        if (machine.resumed and pc != now.pc) machine.resumed = false;
        const stop = machine.onInstruction(now);
        // A unit event with halting off pends DebugMonitor, as step_hook does.
        zig_monitor.take(core, machine);
        if (stop) |why| {
            if (clock) |counting| counting.halted(core, machine, why);
            return .{ .stop = why };
        }
        if (watch) |listening| listening.arm(now.pc, now.size);
        defer if (watch) |listening| listening.disarm();
        const before = core.cpu.slots;
        if (core.cpu.step()) |stopped| return .{ .core = stopped };
        const ran = core.cpu.slots - before;
        retired.* += ran;
        left -= ran;
        if (core.cpu.until) |wait| if (wait.met()) return .count;
        if (core.cpu.cut) |cut| if (cut.fired) return .count;
    }
    return .count;
}

/// What a quiet interval did: architectural slots and the core's own stop.
const Quiet = struct { ran: u64, stop: ?cpu_mod.Stop = null };

/// The rest of a chunk with nothing armed, through `Cpu.run`, so park loops
/// and trips that change nothing go by at once as in a plain run
/// (RA8EMU-712). A store into the PPB ends it, since it may arm the FPB or
/// DWT. An asleep core returns its actual slots. The caller consumes the
/// remaining time without fetching another instruction.
fn quietRun(core: zig_core.ZigCore, watch: ?*watch_bus.WatchBus, left: u64, target: ?u64) Quiet {
    const cpu = core.cpu;
    const before = cpu.slots;
    const previous_until = cpu.until;
    const listening = watch;
    if (listening) |held| {
        held.ppb = .{ .needle = "" };
        held.arm(0, 0);
        held.quiet = true;
        if (previous_until == null) cpu.until = &held.ppb;
    }
    defer if (listening) |held| {
        held.disarm();
        held.quiet = false;
        cpu.until = previous_until;
    };
    const stop = cpu.runToCount(left, target orelse cpu.slots + left);
    const ran = cpu.slots - before;
    if (stop != .count) return .{ .ran = ran, .stop = stop };
    return .{ .ran = ran };
}
