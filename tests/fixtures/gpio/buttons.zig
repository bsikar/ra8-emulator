//! RA8EMU-814 fixture: firmware that mirrors SW1 (P009, active low, read
//! through PORT0's PCNTR2) onto LED1 (blue, P600). While SW1 is held the
//! LED is on, so a press shows up as led_changed 0x100 on the session topic
//! and the release as 0x000. A word at SRAM 0x22000100 counts presses.

/// PCNTR2 of PORT0: the pin levels in the low half.
const port0_pcntr2: *volatile u32 = @ptrFromInt(0x4040_0000 + 0x04);
/// PCNTR1 of PORT6: PDR in the low half, PODR in the high half.
const port6_pcntr1: *volatile u32 = @ptrFromInt(0x4040_0000 + 6 * 0x20);
const sw1: u32 = 1 << 9;
const led1: u32 = 1 << 0;
const presses: *volatile u32 = @ptrFromInt(0x2200_0100);

const Vectors = extern struct {
    sp: u32,
    reset: *const fn () callconv(.c) noreturn,
};

export const vector_table linksection(".isr_vector") = Vectors{
    .sp = 0x2219_FFF8,
    .reset = &Reset_Handler,
};

export fn Reset_Handler() callconv(.c) noreturn {
    presses.* = 0;
    port6_pcntr1.* = led1;
    var lit = false;
    while (true) {
        const held = port0_pcntr2.* & sw1 == 0;
        if (held == lit) continue;
        lit = held;
        port6_pcntr1.* = (if (held) led1 << 16 else 0) | led1;
        if (held) presses.* += 1;
    }
}
