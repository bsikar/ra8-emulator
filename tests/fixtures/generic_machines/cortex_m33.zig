//! Source-built bare-metal fixture for the generic single-core Cortex-M33
//! machine (`cortex-m33`): architectural SCS, SysTick, single-precision FPU,
//! and ITM stimulus port 0 only, with zero vendor peripheral accesses.

const scb_cpuid: *const volatile u32 = @ptrFromInt(0xE000_ED00);
const scb_vtor: *const volatile u32 = @ptrFromInt(0xE000_ED08);
const scb_shcsr: *volatile u32 = @ptrFromInt(0xE000_ED24);
const scb_cfsr: *const volatile u32 = @ptrFromInt(0xE000_ED28);
const scb_cpacr: *volatile u32 = @ptrFromInt(0xE000_ED88);
const mpu_type: *const volatile u32 = @ptrFromInt(0xE000_ED90);
const scb_demcr: *volatile u32 = @ptrFromInt(0xE000_EDFC);

const dwt_ctrl: *const volatile u32 = @ptrFromInt(0xE000_1000);

const syst_csr: *volatile u32 = @ptrFromInt(0xE000_E010);
const syst_rvr: *volatile u32 = @ptrFromInt(0xE000_E014);
const syst_cvr: *volatile u32 = @ptrFromInt(0xE000_E018);

const itm_stim0: *volatile u8 = @ptrFromInt(0xE000_0000);
const itm_stim0_ready: *const volatile u32 = @ptrFromInt(0xE000_0000);
const itm_ter: *volatile u32 = @ptrFromInt(0xE000_0E00);
const itm_tcr: *volatile u32 = @ptrFromInt(0xE000_0E80);

const expected_cpuid: u32 = 0x410F_D210;
const state_magic: u32 = 0x474D_3333; // "GM33"
const fault_magic: u32 = 0xFA01_7000;
const target_ticks: u32 = 4;

pub const StateRecord = extern struct {
    magic: u32,
    cpuid: u32,
    vtor: u32,
    dwt_mpu: u32,
    systick_ticks: u32,
    tick_sum: u32,
    fp32_bits: u32,
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
    if (@sizeOf(VectorTable) != 64) @compileError("VectorTable must be 16 words");
}

export const vector_table linksection(".isr_vector") = VectorTable{
    .sp = 0x2000_3FF8,
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

var tick_count: u32 = 0;
var tick_sum: u32 = 0;

fn initStateRecord() void {
    const words: [*]volatile u32 = @ptrCast(&known_state);
    var i: usize = 0;
    while (i < @sizeOf(StateRecord) / @sizeOf(u32)) : (i += 1) {
        words[i] = 0;
    }
}

fn enableItm() void {
    scb_demcr.* = scb_demcr.* | (1 << 24);
    itm_ter.* = 1;
    itm_tcr.* = 1;
}

fn writeItm(text: []const u8) void {
    for (text) |ch| {
        while ((itm_stim0_ready.* & 1) == 0) {}
        itm_stim0.* = ch;
    }
}

fn computeFp32Bits() u32 {
    scb_cpacr.* = scb_cpacr.* | (0xF << 20);
    asm volatile ("dsb\nisb" ::: .{ .memory = true });
    var a: f32 = 1.5;
    var b: f32 = 4.0;
    var c: f32 = 2.5;
    const a_ptr: *volatile f32 = &a;
    const b_ptr: *volatile f32 = &b;
    const c_ptr: *volatile f32 = &c;
    const out: f32 = a_ptr.* * b_ptr.* + c_ptr.*;
    return @bitCast(out);
}

fn runSysTick() void {
    const cnt_ptr: *volatile u32 = &tick_count;
    const sum_ptr: *volatile u32 = &tick_sum;
    cnt_ptr.* = 0;
    sum_ptr.* = 0;
    syst_rvr.* = 199;
    syst_cvr.* = 0;
    syst_csr.* = 0x07;
    while (cnt_ptr.* < target_ticks) {
        asm volatile ("wfi");
    }
    syst_csr.* = 0x05;
}

export fn SysTick_Handler() callconv(.c) void {
    const cnt_ptr: *volatile u32 = &tick_count;
    const sum_ptr: *volatile u32 = &tick_sum;
    const next = cnt_ptr.* + 1;
    cnt_ptr.* = next;
    sum_ptr.* = sum_ptr.* + next;
}

export fn Fault_Handler() callconv(.c) noreturn {
    const rec: *volatile StateRecord = &known_state;
    rec.magic = fault_magic;
    rec.status = scb_cfsr.*;
    enableItm();
    writeItm("GENERIC FAULT machine=cortex-m33\n");
    generic_park();
}

export fn generic_park() callconv(.c) noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

export fn Reset_Handler() callconv(.c) noreturn {
    scb_shcsr.* = 0x0007_0000;
    initStateRecord();
    enableItm();
    writeItm("GENERIC BOOT machine=cortex-m33\n");

    const cpuid = scb_cpuid.*;
    const vtor = scb_vtor.*;
    const numcomp = dwt_ctrl.* >> 28;
    const dregion = (mpu_type.* >> 8) & 0xFF;
    const dwt_mpu = (numcomp << 16) | dregion;
    const fp32_bits = computeFp32Bits();
    runSysTick();

    const ticks = @as(*const volatile u32, &tick_count).*;
    const sum = @as(*const volatile u32, &tick_sum).*;
    const ok = (cpuid == expected_cpuid) and
        (vtor == 0x0000_0000) and
        (dwt_mpu == 0x0004_0008) and
        (ticks == target_ticks) and
        (sum == 10) and
        (fp32_bits == 0x4108_0000);

    const rec: *volatile StateRecord = &known_state;
    rec.cpuid = cpuid;
    rec.vtor = vtor;
    rec.dwt_mpu = dwt_mpu;
    rec.systick_ticks = ticks;
    rec.tick_sum = sum;
    rec.fp32_bits = fp32_bits;
    rec.status = if (ok) 1 else 2;
    rec.magic = state_magic;

    if (ok) {
        writeItm("GENERIC END machine=cortex-m33 cpuid=410fd210 ticks=4 sum=10 status=PASS\n");
    } else {
        writeItm("GENERIC END machine=cortex-m33 status=FAIL\n");
    }
    generic_park();
}
