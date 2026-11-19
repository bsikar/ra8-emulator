//! Source-built bare-metal fixture for the generic single-core Cortex-M85
//! machine (`cortex-m85`): architectural SCS, SysTick, Armv8.1-M low-overhead
//! loop + Helium MVE + double-precision FPU, and ITM stimulus port 0 only.

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

const expected_cpuid: u32 = 0x410F_D230;
const state_magic: u32 = 0x474D_3835; // "GM85"
const fault_magic: u32 = 0xFA01_7000;
const target_ticks: u32 = 5;

pub const StateRecord = extern struct {
    magic: u32,
    cpuid: u32,
    vtor: u32,
    dwt_mpu: u32,
    systick_ticks: u32,
    lob_mve_sum: u32,
    fp64_hi: u32,
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

fn computeM85Features(fp64_hi_out: *u32) u32 {
    scb_cpacr.* = scb_cpacr.* | (0xF << 20);
    asm volatile ("dsb\nisb" ::: .{ .memory = true });

    // Armv8.1-M low-overhead loop + Helium MVE vector add (5 iterations * 30 = 150).
    var acc: u32 = 0;
    const loops: u32 = 5;
    var lane_val: u32 = 15;
    asm volatile (
        \\vdup.32 q0, %[val]
        \\vadd.i32 q0, q0, q0
        \\vmov %[val], s0
        \\dls lr, %[cnt]
        \\1:
        \\add %[acc], %[acc], %[val]
        \\le lr, 1b
        : [acc] "+r" (acc),
          [val] "+r" (lane_val),
        : [cnt] "r" (loops),
        : .{ .lr = true, .q0 = true, .cpsr = true });

    // Double-precision FPU arithmetic (3.25 * 2.0 + 0.5 = 7.0 -> 0x401C0000_00000000).
    var a: f64 = 3.25;
    var b: f64 = 2.0;
    var c: f64 = 0.5;
    const a_ptr: *volatile f64 = &a;
    const b_ptr: *volatile f64 = &b;
    const c_ptr: *volatile f64 = &c;
    const prod: f64 = a_ptr.* * b_ptr.* + c_ptr.*;
    const bits: u64 = @bitCast(prod);
    fp64_hi_out.* = @truncate(bits >> 32);
    return acc;
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
    writeItm("GENERIC FAULT machine=cortex-m85\n");
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
    writeItm("GENERIC BOOT machine=cortex-m85\n");

    const cpuid = scb_cpuid.*;
    const vtor = scb_vtor.*;
    const numcomp = dwt_ctrl.* >> 28;
    const dregion = (mpu_type.* >> 8) & 0xFF;
    const dwt_mpu = (numcomp << 16) | dregion;
    var fp64_hi: u32 = 0;
    const lob_mve = computeM85Features(&fp64_hi);
    runSysTick();

    const ticks = @as(*const volatile u32, &tick_count).*;
    const sum = @as(*const volatile u32, &tick_sum).*;
    const combined_sum = lob_mve + sum; // 150 + 15 = 165
    const ok = (cpuid == expected_cpuid) and
        (vtor == 0x0000_0000) and
        (dwt_mpu == 0x0008_0008) and
        (ticks == target_ticks) and
        (combined_sum == 165) and
        (fp64_hi == 0x401C_0000);

    const rec: *volatile StateRecord = &known_state;
    rec.cpuid = cpuid;
    rec.vtor = vtor;
    rec.dwt_mpu = dwt_mpu;
    rec.systick_ticks = ticks;
    rec.lob_mve_sum = combined_sum;
    rec.fp64_hi = fp64_hi;
    rec.status = if (ok) 1 else 2;
    rec.magic = state_magic;

    if (ok) {
        writeItm("GENERIC END machine=cortex-m85 cpuid=410fd230 ticks=5 sum=165 status=PASS\n");
    } else {
        writeItm("GENERIC END machine=cortex-m85 status=FAIL\n");
    }
    generic_park();
}
