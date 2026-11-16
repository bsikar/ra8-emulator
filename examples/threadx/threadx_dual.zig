//! RA8EMU-840 fixture: the CPU0 half of a both-cores ThreadX-shaped image,
//! built from Zig (no C, no committed binary). It alternates its
//! current-thread pointer between two stand-in control blocks, stores zero
//! every third round the way ThreadX idles, and raises SVCall each round,
//! so the RTOS trace records switch, idle and ISR entry/leave events the
//! way a real ThreadX image would. CPU1's half is threadx_dual_cpu1.zig.
const Handler = *const fn () callconv(.c) void;

const Vectors = extern struct {
    sp: u32,
    reset: Handler,
    nmi: Handler,
    hard: Handler,
    mpu: Handler,
    bus: Handler,
    usage: Handler,
    r0: Handler,
    r1: Handler,
    r2: Handler,
    r3: Handler,
    svc: Handler,
    debug: Handler,
    r13: Handler,
    pendsv: Handler,
    systick: Handler,
};

const fallback: Handler = &Default_Handler;

export const vector_table linksection(".isr_vector") = Vectors{
    .sp = 0x2208_0000,
    .reset = &Reset_Handler,
    .nmi = fallback,
    .hard = fallback,
    .mpu = fallback,
    .bus = fallback,
    .usage = fallback,
    .r0 = fallback,
    .r1 = fallback,
    .r2 = fallback,
    .r3 = fallback,
    .svc = &SVCall_Handler,
    .debug = fallback,
    .r13 = fallback,
    .pendsv = fallback,
    .systick = fallback,
};

/// The word the RTOS trace watches: the running thread's control block.
export var _tx_thread_current_ptr: u32 = 0;
/// Stand-in control blocks; only their addresses matter.
export var tcb_a: u32 = 0;
export var tcb_b: u32 = 0;
/// The word that counts rounds, and the word the spin burns through.
const rounds: *volatile u32 = @ptrFromInt(0x2200_0100);
const burn: *volatile u32 = @ptrFromInt(0x2200_0104);

fn spin(count: usize) void {
    for (0..count) |_| burn.* +%= 1;
}

export fn Default_Handler() callconv(.c) void {}

export fn SVCall_Handler() callconv(.c) void {
    spin(400);
}

export fn Reset_Handler() callconv(.c) void {
    rounds.* = 0;
    const current: *volatile u32 = &_tx_thread_current_ptr;
    const blocks = [2]u32{ @intFromPtr(&tcb_a), @intFromPtr(&tcb_b) };
    while (true) {
        current.* = blocks[rounds.* % 2];
        spin(1_000);
        asm volatile ("svc #0");
        if (rounds.* % 3 == 0) {
            current.* = 0;
            spin(800);
        }
        rounds.* +%= 1;
    }
}
