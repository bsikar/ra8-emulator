//! Known-state firmware for public DAP, GDB and editor conformance.
const machine = @import("machine.zig");
pub const panic = @import("std").debug.no_panic;
extern const _stack_top: u32;
const Vectors = extern struct { sp: *const u32, reset: *const fn () callconv(.c) noreturn };
export const vector_table linksection(".isr_vector") = Vectors{ .sp = &_stack_top, .reset = &Reset_Handler };

export fn Reset_Handler() callconv(.c) noreturn {
    machine.known_word = 0x11223344;
    machine.stage = 1;
    const setup: *const fn () callconv(.c) void = @ptrCast(&machine.register_setup);
    const probe: *const fn () callconv(.c) void = @ptrCast(&machine.call_probe);
    const loop: *const fn () callconv(.c) noreturn = @ptrCast(&machine.breakpoint_loop);
    setup();
    probe();
    _ = @call(.never_inline, machine.nested_outer, .{35});
    loop();
}
