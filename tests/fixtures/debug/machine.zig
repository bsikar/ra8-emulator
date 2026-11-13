//! Deterministic debugger targets shared by the normal and fault images.
pub export var known_word: u32 = 0x11223344;
pub export var stage: u32 = 0;

pub export fn register_setup() callconv(.naked) void {
    asm volatile (
        \\movw r0, #0x3344
        \\movt r0, #0x1122
        \\movw r1, #0x7788
        \\movt r1, #0x5566
        \\b register_checkpoint
    );
}

pub export fn register_checkpoint() callconv(.naked) void {
    asm volatile (
        \\nop
        \\bx lr
    );
}

pub export fn call_probe() callconv(.naked) void {
    asm volatile (
        \\push {r7, lr}
        \\mov r7, sp
        \\.global call_small
        \\call_small:
        \\bl small_callee
        \\.global after_small
        \\after_small:
        \\nop
        \\.global call_long
        \\call_long:
        \\bl long_callee
        \\.global after_long
        \\after_long:
        \\pop {r7, pc}
    );
}

pub export fn small_callee() callconv(.naked) void {
    asm volatile (
        \\nop
        \\bx lr
    );
}

pub export fn long_callee() callconv(.naked) void {
    asm volatile (
        \\movw r2, #30000
        \\1:
        \\subs r2, #1
        \\bne 1b
        \\bx lr
    );
}

pub export fn nested_inner(value: u32) callconv(.c) u32 {
    const local = value + 7;
    stage = local; // SOURCE_BREAK: nested_inner
    return local;
}

pub export fn nested_outer(value: u32) callconv(.c) u32 {
    return @call(.never_inline, nested_inner, .{value});
}

pub export fn breakpoint_loop() callconv(.naked) noreturn {
    asm volatile (
        \\nop
        \\b breakpoint_loop
    );
}

pub export fn controlled_fault() callconv(.naked) noreturn {
    // The core conformance suite uses this unsupported decode as a fixed-PC stop.
    asm volatile (".short 0xba80");
}
