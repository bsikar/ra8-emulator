//! RA8EMU-820 fixture: the gauge_poll probe loop plus a console report.
//! Firmware polls the MAX17048 fuel gauge at 0x36 on RIIC channel 1 and,
//! every time the answer flips between ack and nack, prints its running
//! counts on SCI8, the board's console channel. The shell sequence test
//! reads those reports to see the firmware notice each hot-plug change.
//!
//! Words at SRAM 0x22000100: polls, acks, nacks, and changes, as before.

const riic: u32 = 0x4025_E100;
const iccr1: u32 = 0x00;
const iccr2: u32 = 0x01;
const icsr2: u32 = 0x09;
const icdrt: u32 = 0x12;

/// MSTPCRB: channel 1 runs once bit 8 is clear, and the console SCI8 once
/// bit 23 is clear (HUM 11.2.7: SCI0..SCI9 are bits 31 down to 22).
const mstpcrb: *volatile u32 = @ptrFromInt(0x4020_3004);
const riic1_stop: u32 = 1 << 8;
const sci8_stop: u32 = 1 << 23;

const gauge: u8 = 0x36;
const out: *volatile [4]u32 = @ptrFromInt(0x2200_0100);

/// SCI_B geometry (RA8EMU console channel): win_base 0x4035_8000 plus
/// stride 0x100 per channel; channel 8 is the console.
const sci8: u32 = 0x4035_8800;
const ccr0: u32 = 0x08;
const tdr: u32 = 0x04;
const csr: u32 = 0x48;
const ccr0_te: u32 = 0x0000_0010;
const csr_tdre: u32 = 0x2000_0000;

const Vectors = extern struct {
    sp: u32,
    reset: *const fn () callconv(.c) noreturn,
};

export const vector_table linksection(".isr_vector") = Vectors{
    .sp = 0x2219_FFF8,
    .reset = &Reset_Handler,
};

fn reg(offset: u32) *volatile u8 {
    return @ptrFromInt(riic + offset);
}

fn sci(offset: u32) *volatile u32 {
    return @ptrFromInt(sci8 + offset);
}

fn waitSet(offset: u32, bit: u8) void {
    while (reg(offset).* & bit == 0) {}
}

/// One address-only write to the gauge: START, address, STOP. True when
/// nothing acknowledged it.
fn probe() bool {
    while (reg(iccr2).* & 0x80 != 0) {}
    reg(iccr2).* = 0x02;
    waitSet(icsr2, 0x80);
    reg(icdrt).* = gauge << 1;
    waitSet(icsr2, 0x40);
    const nacked = reg(icsr2).* & 0x10 != 0;
    reg(iccr2).* = 0x08;
    waitSet(icsr2, 0x08);
    reg(icsr2).* = 0;
    return nacked;
}

fn byte(value: u8) void {
    while (sci(csr).* & csr_tdre == 0) {}
    @as(*volatile u8, @ptrFromInt(sci8 + tdr)).* = value;
}

/// "P=<polls> A=<acks> N=<nacks> C=<changes>\n" on the console.
fn report() void {
    const names = [_]u8{ 'P', 'A', 'N', 'C' };
    for (names, 0..) |name, index| {
        byte(name);
        byte('=');
        var digits: [10]u8 = undefined;
        var used: usize = 0;
        var value = out[index];
        while (true) {
            digits[used] = '0' + @as(u8, @intCast(value % 10));
            used += 1;
            value /= 10;
            if (value == 0) break;
        }
        while (used > 0) {
            used -= 1;
            byte(digits[used]);
        }
        byte(if (index == names.len - 1) '\n' else ' ');
    }
}

export fn Reset_Handler() callconv(.c) noreturn {
    out.* = .{ 0, 0, 0, 0 };
    mstpcrb.* &= ~(riic1_stop | sci8_stop);
    reg(iccr1).* = 0xC0;
    reg(iccr1).* = 0x80;
    sci(ccr0).* |= ccr0_te;
    const ready = "gauge_uart ready\n";
    for (ready) |char| byte(char);
    var last = false;
    while (true) {
        const nacked = probe();
        if (nacked) out[2] +%= 1 else out[1] +%= 1;
        if (out[0] != 0 and nacked != last) {
            out[3] +%= 1;
            report();
        }
        last = nacked;
        out[0] +%= 1;
    }
}
