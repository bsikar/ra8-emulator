//! Known-state bare-metal fixture for FPB-RA4T1 (RTK7FPA4T1S00001BE /
//! R7FA4T1BB3CFM, sole primary Cortex-M33). Every constant comes from RA4T1
//! hardware references (RA8EMU-A-71: R01UH0999EJ0140 Rev.1.40 and
//! R20UT5524EG0100 Rev.1.00), never from RA8D2 tables.

const scb_cpuid: *const volatile u32 = @ptrFromInt(0xE000_ED00);
const scb_vtor: *volatile u32 = @ptrFromInt(0xE000_ED08);

const syst_csr: *volatile u32 = @ptrFromInt(0xE000_E010);
const syst_rvr: *volatile u32 = @ptrFromInt(0xE000_E014);
const syst_cvr: *volatile u32 = @ptrFromInt(0xE000_E018);
const syst_calib: *const volatile u32 = @ptrFromInt(0xE000_E01C);

const sysc_sckdivcr: *volatile u32 = @ptrFromInt(0x4001_E020);
const sysc_sckscr: *volatile u8 = @ptrFromInt(0x4001_E026);
const sysc_hococr: *volatile u8 = @ptrFromInt(0x4001_E036);
const sysc_hococr2: *volatile u8 = @ptrFromInt(0x4001_E037);
const sysc_oscsf: *const volatile u8 = @ptrFromInt(0x4001_E03C);
const sysc_prcr: *volatile u16 = @ptrFromInt(0x4001_E3FE);
const fcache_flwt: *volatile u8 = @ptrFromInt(0x4001_C11C);

const mstp_mstpcrb: *volatile u32 = @ptrFromInt(0x4008_4004);

const port2_pcntr1: *volatile u32 = @ptrFromInt(0x4008_0040);
const port2_pcntr2: *const volatile u32 = @ptrFromInt(0x4008_0044);
const pfs_p109pfs: *volatile u32 = @ptrFromInt(0x4008_0864);
const pfs_p110pfs: *volatile u32 = @ptrFromInt(0x4008_0868);
const pfs_pwpr: *volatile u8 = @ptrFromInt(0x4008_0D03);

const sci9_smr: *volatile u8 = @ptrFromInt(0x4011_8900);
const sci9_brr: *volatile u8 = @ptrFromInt(0x4011_8901);
const sci9_scr: *volatile u8 = @ptrFromInt(0x4011_8902);
const sci9_tdr: *volatile u8 = @ptrFromInt(0x4011_8903);
const sci9_ssr: *const volatile u8 = @ptrFromInt(0x4011_8904);
const sci9_scmr: *volatile u8 = @ptrFromInt(0x4011_8906);
const sci9_semr: *volatile u8 = @ptrFromInt(0x4011_8907);
const sci9_simr1: *volatile u8 = @ptrFromInt(0x4011_8909);
const sci9_spmr: *volatile u8 = @ptrFromInt(0x4011_890D);
const sci9_mddr: *volatile u8 = @ptrFromInt(0x4011_8912);
const sci9_fcr: *volatile u16 = @ptrFromInt(0x4011_8914);
const sci9_sptr: *volatile u8 = @ptrFromInt(0x4011_8920);

const expected_cpuid: u32 = 0x410F_D214;
const state_magic: u32 = 0x5241_3454; // "RA4T"
const fault_magic: u32 = 0xFA01_7000;
const led1_bit: u32 = 1 << 7; // P207 (LED1, green, active high)
const target_ticks: u32 = 3;

pub const StateRecord = extern struct {
    magic: u32,
    cpuid: u32,
    reset_vtor: u32,
    scksel: u32,
    oscsf: u32,
    syst_calib: u32,
    systick_ticks: u32,
    led_transitions: u32,
    port2_pidr: u32,
    tx_bytes: u32,
    status: u32,
};

export var known_state: StateRecord align(4) linksection(".known_state") = undefined;

const Handler = *const fn () callconv(.c) void;

const VectorTable = extern struct {
    sp: u32,
    reset: *const fn () callconv(.c) noreturn,
    nmi: Handler,
    hard_fault: Handler,
    mem_manage: Handler,
    bus_fault: Handler,
    usage_fault: Handler,
    secure_fault: Handler,
    reserved0: [3]u32,
    svcall: Handler,
    debug_mon: Handler,
    reserved1: u32,
    pendsv: Handler,
    systick: Handler,
};

comptime {
    if (@sizeOf(VectorTable) != 64) @compileError("VectorTable must be 16 words (64 bytes)");
}

export const vector_table linksection(".isr_vector") = VectorTable{
    .sp = 0x2000_9FF8,
    .reset = &Reset_Handler,
    .nmi = &Fault_Handler,
    .hard_fault = &Fault_Handler,
    .mem_manage = &Fault_Handler,
    .bus_fault = &Fault_Handler,
    .usage_fault = &Fault_Handler,
    .secure_fault = &Fault_Handler,
    .reserved0 = .{ 0, 0, 0 },
    .svcall = &Fault_Handler,
    .debug_mon = &Fault_Handler,
    .reserved1 = 0,
    .pendsv = &Fault_Handler,
    .systick = &SysTick_Handler,
};

fn spinNops(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        asm volatile ("nop");
    }
}

fn initClockHoco20M() void {
    sysc_prcr.* = 0xA503; // Unlock PRC0 (CGC) and PRC1 (LPM).
    fcache_flwt.* = 0x00; // 0 flash wait states valid up to ICLK <= 50 MHz.
    sysc_sckscr.* = 0x01; // Run on MOCO while configuring HOCO.
    sysc_hococr.* = 0x01; // Stop HOCO before writing HOCOCR2.
    while ((sysc_oscsf.* & 0x01) != 0) {}
    sysc_hococr2.* = 0x02; // 20 MHz (HCFRQ0 = 10b; blank OFS1 leaves 11b).
    sysc_hococr.* = 0x00; // Start HOCO.
    while ((sysc_oscsf.* & 0x01) == 0) {}
    sysc_sckdivcr.* = 0x0000_0000; // All dividers /1 -> 20 MHz (<= 50 MHz PCLKB/FCLK).
    sysc_sckscr.* = 0x00; // Switch system clock to HOCO.
    _ = sysc_sckscr.*;
    sysc_prcr.* = 0xA500;
}

fn initSci9Vcom() void {
    mstp_mstpcrb.* &= ~(@as(u32, 1) << 22); // Release classic SCI9 module stop.
    _ = mstp_mstpcrb.*;

    sci9_scr.* = 0x00;
    sci9_fcr.* = 0xF800; // Non-FIFO mode (FM = 0).
    sci9_simr1.* = 0x00;
    sci9_spmr.* = 0x00;
    sci9_smr.* = 0x00; // Async 8N1, PCLKA/1 (n = 0).
    sci9_scmr.* = 0xF2; // SMIF=0, SDIR=0 (LSB-first), CHR1=1 (8-bit), BCP2=1.
    sci9_semr.* = 0x04; // BRME=1 (bit-rate modulation), BGDM=0, ABCS=0.
    sci9_sptr.* = 0x06; // Hold TXD9 high while TE = 0 (SPB2IO | SPB2DT).
    sci9_brr.* = 4; // N = 4, M = 236 -> 115,234.4 bps (+0.03%) at 20 MHz.
    sci9_mddr.* = 236;

    // On RA4T1 PmSAR resets to 0xFFFF (Non-secure), so PWPR (0x4008_0D03) gates PFS.
    pfs_pwpr.* = 0x00; // Clear B0WI.
    pfs_pwpr.* = 0x40; // Set PFSWE.
    pfs_p109pfs.* = 0x0500_0405; // P109 = TXD9 (PSEL = 0x05), idle-high latch.
    pfs_p109pfs.* = 0x0501_0405; // Enable peripheral mux.
    pfs_p110pfs.* = 0x0500_0000; // P110 = RXD9 (PSEL = 0x05), PMR = 0 first.
    pfs_p110pfs.* = 0x0501_0000; // Enable peripheral mux.
    pfs_pwpr.* = 0x00;
    pfs_pwpr.* = 0x80; // Re-lock B0WI.

    sci9_scr.* = 0x30; // Enable TE | RE.
    spinNops(6_000); // > 2 UART frames of mark-high idle for J-Link OB VCOM.
}

fn writeByte(b: u8) void {
    while ((sci9_ssr.* & 0x80) == 0) {} // Poll SSR.TDRE.
    sci9_tdr.* = b;
    @as(*volatile u32, @ptrCast(&known_state.tx_bytes)).* += 1;
}

fn writeStr(s: []const u8) void {
    for (s) |b| {
        writeByte(b);
    }
}

fn writeHex32(value: u32) void {
    const digits = "0123456789abcdef";
    var shift: u5 = 28;
    while (true) : (shift -= 4) {
        const nibble: usize = @intCast((value >> shift) & 0xF);
        writeByte(digits[nibble]);
        if (shift == 0) break;
    }
}

fn runSysTickAndLed() void {
    port2_pcntr1.* = led1_bit; // P207 output, initial low.
    syst_csr.* = 0;
    syst_rvr.* = 3_999; // 4,000 cycles = 200 us per tick at 20 MHz.
    syst_cvr.* = 0;
    asm volatile ("cpsie i" ::: .{ .memory = true });
    syst_csr.* = 0x0000_0007; // ENABLE | TICKINT | CLKSOURCE (ICLK).
    const ticks_ptr: *const volatile u32 = @ptrCast(&known_state.systick_ticks);
    while (ticks_ptr.* < target_ticks) {
        asm volatile ("nop");
    }
}

export fn SysTick_Handler() callconv(.c) void {
    const ticks_ptr: *volatile u32 = @ptrCast(&known_state.systick_ticks);
    const edges_ptr: *volatile u32 = @ptrCast(&known_state.led_transitions);
    const next = ticks_ptr.* + 1;
    ticks_ptr.* = next;
    // Tick 1 -> high, Tick 2 -> low, Tick 3 -> high (3 edges, ends ON).
    const high = (next & 1) == 1;
    port2_pcntr1.* = (if (high) (led1_bit << 16) else 0) | led1_bit;
    edges_ptr.* += 1;
    if (next >= target_ticks) {
        syst_csr.* = 0x0000_0005; // Keep counting with TICKINT cleared.
    }
}

export fn Fault_Handler() callconv(.c) void {
    const ipsr = asm volatile ("mrs %[out], ipsr"
        : [out] "=r" (-> u32),
    );
    @as(*volatile u32, @ptrCast(&known_state.magic)).* = fault_magic | (ipsr & 0x1FF);
    @as(*volatile u32, @ptrCast(&known_state.status)).* = 0xDEAD;
    while (true) {
        asm volatile ("nop");
    }
}

export fn known_state_park() callconv(.c) noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

fn initStateRecord(initial_vtor: u32) void {
    const words: *[11]u32 = @ptrCast(&known_state);
    for (words) |*w| {
        @as(*volatile u32, w).* = 0;
    }
    @as(*volatile u32, @ptrCast(&known_state.cpuid)).* = scb_cpuid.*;
    @as(*volatile u32, @ptrCast(&known_state.reset_vtor)).* = initial_vtor;
    @as(*volatile u32, @ptrCast(&known_state.scksel)).* = 0xFF;
    @as(*volatile u32, @ptrCast(&known_state.syst_calib)).* = syst_calib.*;
}

export fn Reset_Handler() callconv(.c) noreturn {
    const initial_vtor = scb_vtor.*;
    scb_vtor.* = @intFromPtr(&vector_table);
    initStateRecord(initial_vtor);

    initClockHoco20M();
    const scksel: u32 = sysc_sckscr.*;
    const oscsf: u32 = sysc_oscsf.*;
    @as(*volatile u32, @ptrCast(&known_state.scksel)).* = scksel;
    @as(*volatile u32, @ptrCast(&known_state.oscsf)).* = oscsf;

    initSci9Vcom();
    writeStr("RA8EMU KNOWN-STATE BOOT board=fpb-ra4t1 part=r7fa4t1bb3cfm core=cortex-m33\r\n");

    runSysTickAndLed();

    const pidr = port2_pcntr2.* & 0xFFFF;
    @as(*volatile u32, @ptrCast(&known_state.port2_pidr)).* = pidr;
    const cpuid = @as(*const volatile u32, @ptrCast(&known_state.cpuid)).*;
    const ticks = @as(*const volatile u32, @ptrCast(&known_state.systick_ticks)).*;
    const edges = @as(*const volatile u32, @ptrCast(&known_state.led_transitions)).*;
    const led1_on = (pidr & led1_bit) != 0;
    const ok = (cpuid == expected_cpuid) and
        (scksel == 0) and
        ((oscsf & 0x01) == 1) and
        (ticks == target_ticks) and
        (edges == target_ticks) and
        led1_on;
    @as(*volatile u32, @ptrCast(&known_state.status)).* = if (ok) 1 else 2;
    @as(*volatile u32, @ptrCast(&known_state.magic)).* = state_magic;

    writeStr("RA8EMU KNOWN-STATE END board=fpb-ra4t1 cpuid=");
    writeHex32(cpuid);
    writeStr(" clk=hoco20m systick=");
    writeByte(@as(u8, @truncate('0' + (ticks & 0x7))));
    writeStr(" led1=");
    writeByte(if (led1_on) '1' else '0');
    writeStr(if (ok) " status=PASS\r\n" else " status=FAIL\r\n");
    while ((sci9_ssr.* & 0x04) == 0) {} // Wait SSR.TEND after final byte.

    known_state_park();
}
