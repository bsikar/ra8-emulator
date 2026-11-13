//! RA8EMU-725: poll SCI8 and echo each received byte without IRQ setup.
const rdr: *volatile u32 = @ptrFromInt(0x4035_8800);
const tdr: *volatile u32 = @ptrFromInt(0x4035_8804);
const ccr0: *volatile u32 = @ptrFromInt(0x4035_8808);
const csr: *volatile u32 = @ptrFromInt(0x4035_8848);
const mstpcrb: *volatile u32 = @ptrFromInt(0x4020_3004);
const received: *volatile u32 = @ptrFromInt(0x2200_0100);
const Vectors = extern struct {
    sp: u32,
    reset: *const fn () callconv(.c) noreturn,
};
export const vector_table linksection(".isr_vector") = Vectors{
    .sp = 0x2219_FFF8,
    .reset = &Reset_Handler,
};
export fn Reset_Handler() callconv(.c) noreturn {
    received.* = 0;
    mstpcrb.* &= ~@as(u32, 1 << 23); // SCI8 module stop
    ccr0.* = 0x11; // RE | TE
    while (true) {
        if (csr.* & 0x8000_0000 == 0) continue; // RDRF
        const byte = rdr.* & 0xFF;
        tdr.* = byte;
        received.* += 1;
    }
}
