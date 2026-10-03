//! Exception entry: stack the basic frame on the stack in use, leave
//! EXC_RETURN in LR, and branch to the handler the vector table names, in
//! Handler mode on the Main stack.
//!
//! R0-R3 and R12 are left as they were (the architecture makes them
//! UNKNOWN). Whether an exception may be taken at all, and the active stack,
//! are dispatch.zig's; this is only the architectural entry sequence.
const bus = @import("../bus.zig");
const regs_mod = @import("../regs.zig");
const memmap = @import("../../memmap.zig");
const Cpu = @import("../cpu.zig").Cpu;
const frame = @import("frame.zig");
const fp_frame = @import("fp_frame.zig");
const exc_return = @import("exc_return.zig");

/// EPSR.ICI/IT and B; exception entry clears each from live xPSR.
pub const it_bits: u32 = (0x3 << 25) | (0x3F << 10) | regs_mod.xpsr_bits.bti;

pub const Number = u9;

/// Take exception `number`, with `return_address` stacked as where to resume.
pub fn take(cpu: *Cpu, number: Number, return_address: u32) bus.Error!bool {
    const r = &cpu.regs;
    cpu.exclusive = null;
    const handler = try cpu.bus.readWord(vectorTable(cpu) +% @as(u32, number) * 4);
    const stacked: frame.Frame = .{
        r.low[0],  r.low[1], r.low[2],       r.low[3],
        r.low[12], r.lr,     return_address, r.xpsr,
    };
    const fp = r.control & regs_mod.control_bits.fpca != 0;
    const from: exc_return.Target = .{
        .thread = !r.handlerMode(),
        .psp = r.usesPsp(),
        .fp = fp,
        .secure = cpu.banked.current == .secure,
    };
    const size = if (fp) fp_frame.size else frame.size;
    const at = frameAddress(r.sp(), size);
    const limit = r.spLimit();
    const overflow = limit != 0 and at < limit;
    if (overflow) {
        // DDI0553 B3.21: exception entry sets SP to the limit and does not
        // push frame words below it. The derived STKOF UsageFault is selected
        // by dispatch after the original entry has established its context.
        r.setSp(limit);
    } else {
        const pushed = if (fp)
            try fp_frame.push(cpu.bus, r.sp(), stacked, fpContext(cpu))
        else
            try frame.push(cpu.bus, r.sp(), stacked);
        r.setSp(pushed);
    }
    r.lr = exc_return.forEntry(from);
    r.control &= ~(regs_mod.control_bits.spsel | regs_mod.control_bits.fpca);
    land(cpu, number, handler);
    return overflow;
}

fn frameAddress(sp: u32, size: u32) u32 {
    return (sp -% size) & ~(sp & 4);
}

/// S0-S15, FPSCR and, with MVE, VPR as the extended frame stacks them.
/// Stacking is eager; lazy preservation is RA8EMU-163.
fn fpContext(cpu: *const Cpu) fp_frame.Fp {
    const vpr: u32 = if (cpu.profile.mve) @bitCast(cpu.fp.vpr) else 0;
    var fp: fp_frame.Fp = .{ .s = undefined, .fpscr = cpu.fp.fpscr.bits(), .vpr = vpr };
    for (&fp.s, 0..) |*s, i| s.* = cpu.fp.bank.readS(@intCast(i));
    return fp;
}

/// Redirect an in-progress entry to a derived exception without stacking
/// again. LR already contains EXC_RETURN for the interrupted context.
pub fn retarget(cpu: *Cpu, number: Number) bus.Error!void {
    const handler = try cpu.bus.readWord(vectorTable(cpu) +% @as(u32, number) * 4);
    land(cpu, number, handler);
}

/// Take exception `number` without stacking a frame, with `lr` as the link
/// value: a fault raised by a failed exception return, whose frame is still
/// on the stack where the return found it.
pub fn chain(cpu: *Cpu, number: Number, lr: u32) bus.Error!void {
    cpu.exclusive = null;
    const handler = try cpu.bus.readWord(vectorTable(cpu) +% @as(u32, number) * 4);
    cpu.regs.lr = lr;
    land(cpu, number, handler);
}

/// IPSR, EPSR.T and the PC for a handler about to run. Entry also sets the
/// event register.
fn land(cpu: *Cpu, number: Number, handler: u32) void {
    const r = &cpu.regs;
    cpu.event = true;
    r.xpsr = (r.xpsr & ~(it_bits | regs_mod.xpsr_bits.ipsr)) | number;
    const thumb = regs_mod.xpsr_bits.thumb;
    r.xpsr = if (handler & 1 != 0) r.xpsr | thumb else r.xpsr & ~thumb;
    r.pc = handler & ~@as(u32, 1);
}

/// VTOR as the firmware set it, or the table the core reset from while
/// nothing answers at VTOR or it still reads zero.
pub fn vectorTable(cpu: *const Cpu) u32 {
    const vtor = cpu.bus.readWord(memmap.scb.vtor) catch 0;
    return if (vtor != 0) vtor else cpu.vtor;
}
