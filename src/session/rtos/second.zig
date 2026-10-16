//! `--trace-rtos` on CPU1, as core 1 (RA8EMU-262).
//!
//! CPU1 runs its own image on its own Zig core and store, with its own
//! clock, so it gets its own tracer: the symbol is looked up in the CPU1
//! image, a listener sits in front of CPU1's bus and exception source, and
//! every event is tagged cpu1. CPU0's tracer is untouched.
//!
//! The run owns the tracer state (`Tracers`): a run has at most one CPU1
//! and so at most one of these, and it lives as long as the run's CPU1.
const std = @import("std");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const elf = @import("ra8_board").image.elf;
const second_core = @import("ra8_chip").core.second.core;
const rtos_hook = @import("hook.zig");

/// CPU1's tracer state, owned by the run that armed it: a run has at most
/// one CPU1, so its tracer and listener live inside the run instead of
/// this module (RA8EMU-181's per-machine rule).
pub const Tracers = struct {
    /// The tracer `print` reports, once CPU1 was traced.
    tracer: ?*rtos_hook.Tracer = null,
    zig_tracer: rtos_hook.Tracer = undefined,
    zig_listener: rtos_hook.zig.Listener = undefined,
};

/// CPU1's trace and load, names read through CPU1's memory. Nothing when
/// there is no CPU1 or it was not traced.
pub fn print(out: anytype, io: std.Io, dir: std.Io.Dir, options: anytype, tracers: *const Tracers, second: ?Guest) !void {
    try printOn(out, io, dir, options, tracers, second orelse return);
}

/// `print` for a CPU1 whose memory is `memory`, engine or store (RA8EMU-588).
pub fn printOn(out: anytype, io: std.Io, dir: std.Io.Dir, options: anytype, tracers: *const Tracers, memory: Guest) !void {
    const tracer = tracers.tracer orelse return;
    try rtos_hook.report.all(out, io, dir, options, tracer, rtos_hook.Memory{ .guest = memory });
}

/// CPU1's tracer and the memory its names are read through, for
/// `--report json` (RA8EMU-266, RA8EMU-588). Null when CPU1 was not traced.
pub fn sideOn(tracers: *const Tracers, memory: Guest) ?rtos_hook.report.Side {
    const tracer = tracers.tracer orelse return null;
    return .{ .tracer = tracer, .memory = .{ .guest = memory } };
}

/// `--trace-rtos` on CPU1's Zig core under `--cpu zig --cpu1` (RA8EMU-341).
/// The listener sits in front of CPU1's bus and exception source, as
/// rtos_zig.zig does for CPU0; stamps come from CPU1's own SysTick count
/// and load from its retired count. `print` then reports it as cpu1.
pub fn armZig(pair: *second_core.zig.run.Driver, io: std.Io, dir: std.Io.Dir, wanted: ?rtos_hook.load.Window, path: ?[]const u8, tracers: *Tracers) void {
    const named = path orelse return;
    if (wanted == null) return;
    const bytes = dir.readFileAlloc(io, named, std.heap.page_allocator, .limited(second_core.limits.image_bytes)) catch return;
    const image = elf.Image.init(bytes) catch return;
    tracers.zig_tracer = rtos_hook.resolveOn(image, wanted, 1) orelse return;
    listenZig(pair, &tracers.zig_tracer, tracers);
}

/// Put `tracer` in front of CPU1's Zig core and make it the one `print` reports.
pub fn listenZig(pair: *second_core.zig.run.Driver, tracer: *rtos_hook.Tracer, tracers: *Tracers) void {
    tracer.now = &pair.second.state.timebase.ticks;
    tracer.trace.fine = &pair.core.cpu.retired;
    tracers.zig_listener = .{ .tracer = tracer };
    const cpu = &pair.core.cpu;
    cpu.bus = tracers.zig_listener.onBus(cpu.bus);
    if (cpu.source) |inner| cpu.source = tracers.zig_listener.onSource(inner);
    tracers.tracer = tracer;
}
