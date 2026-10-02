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
const exc_return = @import("exc_return.zig");

/// EPSR.ICI/IT, bits 26:25 and 15:10; entry clears them.
pub const it_bits: u32 = (0x3 << 25) | (0x3F << 10);

pub const Number = u9;

/// Take exception `number`, with `return_address` stacked as where to resume.
pub fn take(cpu: *Cpu, number: Number, return_address: u32) bus.Error!void {
    const r = &cpu.regs;
    cpu.exclusive = null;
    const handler = try cpu.bus.readWord(vectorTable(cpu) +% @as(u32, number) * 4);
    const stacked: frame.Frame = .{
        r.low[0],  r.low[1], r.low[2],       r.low[3],
        r.low[12], r.lr,     return_address, r.xpsr,
    };
    const from: exc_return.Target = .{ .thread = !r.handlerMode(), .psp = r.usesPsp() };
    r.setSp(try frame.push(cpu.bus, r.sp(), stacked));
    r.lr = exc_return.forEntry(from);
    r.control &= ~regs_mod.control_bits.spsel;
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

/// IPSR, EPSR.T and the PC for a handler about to run.
fn land(cpu: *Cpu, number: Number, handler: u32) void {
    const r = &cpu.regs;
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
