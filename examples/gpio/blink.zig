//! RA8EMU-811 fixture: firmware that blinks LED1 (blue, P600) twice and
//! then parks. P600 goes to output low, then high, low, high, low, so the
//! session sees four led_changed events for LED 0 in that order. A word at
//! SRAM 0x22000100 counts the level writes; it reads 4 once the blinking
//! is done.

/// PCNTR1 of PORT6: PDR in the low half, PODR in the high half.
const port6_pcntr1: *volatile u32 = @ptrFromInt(0x4040_0000 + 6 * 0x20);
const led1: u32 = 1 << 0;
const done: *volatile u32 = @ptrFromInt(0x2200_0100);

const Vectors = extern struct {
    sp: u32,
    reset: *const fn () callconv(.c) noreturn,
};

export const vector_table linksection(".isr_vector") = Vectors{
    .sp = 0x2219_FFF8,
    .reset = &Reset_Handler,
};

fn pause() void {
    var count: u32 = 0;
    while (count < 200) : (count += 1) asm volatile ("nop");
}

export fn Reset_Handler() callconv(.c) noreturn {
    done.* = 0;
    port6_pcntr1.* = led1;
    for (0..4) |step| {
        pause();
        const high = step % 2 == 0;
        port6_pcntr1.* = (if (high) led1 << 16 else 0) | led1;
        done.* += 1;
    }
    while (true) {}
}
