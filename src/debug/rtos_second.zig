//! `--trace-rtos` on CPU1, as core 1 (RA8EMU-262).
//!
//! CPU1 runs its own image on its own engine, with its own NVIC model and
//! its own clock, so it gets its own tracer: the symbol is looked up in the
//! CPU1 image, the stores and exceptions are hooked on CPU1's engine, and
//! every event is tagged cpu1. CPU0's tracer is untouched.
//!
//! The tracer is kept here because the run holds CPU1 as a bare
//! `?*Second`; a run has at most one CPU1 and so at most one of these, and
//! like rtos_hook.arm's it lives until the process ends.
const std = @import("std");
const elf = @import("../core/elf.zig");
const second_core = @import("../core/second_core.zig");
const rtos_hook = @import("rtos_hook.zig");

var traced: ?*rtos_hook.Tracer = null;
var zig_tracer: rtos_hook.Tracer = undefined;
var zig_listener: rtos_hook.zig.Listener = undefined;

/// Pass CPU1 through, tracing it when the flag asked and its image (read
/// again from `path`) has ThreadX. Bringing CPU1 up failing is passed on
/// as it was; a trace that cannot be armed leaves the run as it would be.
pub fn arm(started: anyerror!?*second_core.Second, wanted: ?rtos_hook.load.Window, path: ?[]const u8) anyerror!?*second_core.Second {
    const one = (try started) orelse return null;
    const window = wanted orelse return one;
    const named = path orelse return one;
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, named, second_core.limits.image_bytes) catch return one;
    const image = elf.Image.init(bytes) catch return one;
    const found = rtos_hook.resolveOn(image, window, 1) orelse return one;
    traced = rtos_hook.attach(one.core.handle, found, &one.timebase.ticks, &one.interrupts) catch null;
    if (traced) |tracer| tracer.elapsed = &one.timebase.elapsed;
    return one;
}

/// CPU1's trace and load, names read through CPU1's engine. Nothing when CPU1 was
/// not traced.
pub fn print(out: anytype, options: anytype, second: ?*const second_core.Second) !void {
    const one = second orelse return;
    const tracer = traced orelse return;
    try rtos_hook.report.all(out, options, tracer, rtos_hook.Memory{ .handle = one.core.handle });
}

/// `--trace-rtos` on CPU1's Zig core under `--cpu zig --cpu1` (RA8EMU-341).
/// The listener sits in front of CPU1's bus and exception source, as
/// rtos_zig.zig does for CPU0; stamps come from CPU1's own SysTick count
/// and load from its retired count. `print` then reports it as cpu1.
pub fn armZig(pair: *second_core.zig_run.Driver, wanted: ?rtos_hook.load.Window, path: ?[]const u8) void {
    const named = path orelse return;
    if (wanted == null) return;
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, named, second_core.limits.image_bytes) catch return;
    const image = elf.Image.init(bytes) catch return;
    zig_tracer = rtos_hook.resolveOn(image, wanted, 1) orelse return;
    listenZig(pair, &zig_tracer);
}

/// Put `tracer` in front of CPU1's Zig core and make it the one `print` reports.
pub fn listenZig(pair: *second_core.zig_run.Driver, tracer: *rtos_hook.Tracer) void {
    tracer.now = &pair.second.timebase.ticks;
    tracer.trace.fine = &pair.core.cpu.retired;
    zig_listener = .{ .tracer = tracer };
    const cpu = &pair.core.cpu;
    cpu.bus = zig_listener.onBus(cpu.bus);
    if (cpu.source) |inner| cpu.source = zig_listener.onSource(inner);
    traced = tracer;
}
