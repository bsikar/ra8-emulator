//! The stop machine fed from the Zig core (RA8EMU-105). On Unicorn,
//! step_hook.zig's code hook hands the machine each instruction before it
//! runs; here the debugger owns the loop, so it builds the same event,
//! asks the machine, and only then lets the core execute.
const std = @import("std");
const zig_core = @import("zig_core.zig");
const stop_machine = @import("stop_machine.zig");
const call_decode = @import("call_decode.zig");
const cpu_mod = @import("../core/cpu/cpu.zig");
const dispatch = @import("../core/cpu/exception/dispatch.zig");
const watch_bus = @import("watch_bus.zig");

/// How a driven run ended.
pub const Ended = union(enum) {
    /// The machine stopped the core before the instruction at the PC ran.
    stop: stop_machine.Stop,
    /// Every instruction allowed ran without a stop.
    count,
    /// The core itself stopped (an unknown encoding, a bus fault, ...).
    core: cpu_mod.Stop,
};

/// The event for the instruction under the PC, as the Unicorn hook builds
/// it: its address and width, SP before it runs, and whether it is a call.
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
/// instruction makes (RA8EMU-113), the way step_hook.zig's memory hook does
/// on Unicorn. It listens only while the instruction runs, so neither the
/// debugger's own reads nor the instruction's fetch count as an access.
pub fn runWatched(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64, watch: ?*watch_bus.WatchBus) Ended {
    var left = count;
    while (left > 0) : (left -= 1) {
        _ = dispatch.poll(core.cpu) catch return .{ .core = .{ .bus_fault = core.register(.pc) } };
        const now = event(core);
        if (machine.onInstruction(now)) |why| return .{ .stop = why };
        if (watch) |listening| listening.arm(now.pc, now.size);
        defer if (watch) |listening| listening.disarm();
        if (core.cpu.step()) |stopped| return .{ .core = stopped };
    }
    return .count;
}
