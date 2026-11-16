//! Nonempty SCI1 receive FIFO for real-GDB debugger-read stability checks.
//! Model contract: sci/spi.zig and tests/chip/periph/sci/spi_test.zig.
//! CCR3.MOD=011 clocks one idle 0xff into RX per TDR store on this unattached line.
//! RDR reads pop once; debugger peeks must leave all three bytes for the guest.
pub const panic = @import("std").debug.no_panic;
extern const _stack_top: u32;
const Vectors = extern struct { sp: *const u32, reset: *const fn () callconv(.c) noreturn };
export const vector_table linksection(".isr_vector") = Vectors{ .sp = &_stack_top, .reset = &Reset_Handler };

const registers = struct {
    // mstp/mstp.zig: MSTPCRB +4, SCI1 bit30 (HUM 11.2.7 p444-445).
    const mstpcrb: *volatile u32 = @ptrFromInt(0x4020_3004);
    // sci/sci.zig: SCI1 base +0x100, RDR/TDR/CCR0/CSR offsets.
    const rdr: *volatile u32 = @ptrFromInt(0x4035_8100);
    const tdr: *volatile u32 = @ptrFromInt(0x4035_8104);
    const ccr0: *volatile u32 = @ptrFromInt(0x4035_8108);
    // sci/spi.zig: CCR3 +0x14 (HUM38.2.8 p2203); MOD field bits18:16.
    const ccr3: *volatile u32 = @ptrFromInt(0x4035_8114);
    const csr: *volatile u32 = @ptrFromInt(0x4035_8148);
};

export var pending_status_before: u32 = 0;
export var drained: [3]u32 = .{ 0, 0, 0 };
export var status_after_first: u32 = 0;
export var status_after_second: u32 = 0;
export var status_after_third: u32 = 0;
export var empty_read: u32 = 0xDEAD_BEEF;

export fn fifo_ready() callconv(.c) void {
    asm volatile ("nop");
}

export fn fifo_drained() callconv(.c) noreturn {
    while (true) asm volatile ("nop");
}

export fn Reset_Handler() callconv(.c) noreturn {
    registers.mstpcrb.* &= ~@as(u32, 1 << 30);
    registers.ccr3.* = 0x0003_0000;
    registers.ccr0.* = 0x11; // CCR0.TE | CCR0.RE, as sci/spi_test configures.
    registers.tdr.* = 0x40;
    registers.tdr.* = 0x41;
    registers.tdr.* = 0x42;
    pending_status_before = registers.csr.*;
    @call(.never_inline, fifo_ready, .{});
    drained[0] = registers.rdr.*;
    status_after_first = registers.csr.*;
    drained[1] = registers.rdr.*;
    status_after_second = registers.csr.*;
    drained[2] = registers.rdr.*;
    status_after_third = registers.csr.*;
    empty_read = registers.rdr.*;
    @call(.never_inline, fifo_drained, .{});
}
