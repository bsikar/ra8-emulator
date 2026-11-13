//! Separate entry makes the controlled fault reachable through DAP alone.
const machine = @import("machine.zig");
pub const panic = @import("std").debug.no_panic;
extern const _stack_top: u32;
const Vectors = extern struct { sp: *const u32, reset: *const fn () callconv(.c) noreturn };
export const vector_table linksection(".isr_vector") = Vectors{ .sp = &_stack_top, .reset = &Reset_Handler };
export fn Reset_Handler() callconv(.c) noreturn {
    const fault: *const fn () callconv(.c) noreturn = @ptrCast(&machine.controlled_fault);
    fault();
}
