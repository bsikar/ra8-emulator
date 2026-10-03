//! The integer divide trap Unicorn does not raise itself.
//!
//! A code hook watches encoded SDIV/UDIV instructions. When CCR.DIV_0_TRP is
//! set and Rm is zero, it latches UFSR.DIVBYZERO and enters the routed fault.
const std = @import("std");
const c = @import("c.zig");
const elf = @import("elf.zig");
const engine = @import("engine.zig");
const cond = @import("cpu/cond.zig");
const Instr = @import("cpu/instr.zig").Instr;
const divide = @import("cpu/ops/divide.zig");
const it_state = @import("cpu/it_state.zig");
const memmap = @import("memmap.zig");
const fault_route = @import("../periph/fault_route.zig");
const fault_status = @import("../periph/fault_status.zig");
const nvic = @import("../periph/nvic.zig");

pub const Error = error{AttachFailed};
pub const width: usize = 4;
pub const sites_limit: usize = 4096;
const it_bits: u32 = 0x0600_FC00;
const div_0_trp: u32 = 1 << 4;

pub const Operands = struct { rd: u4, rn: u4, rm: u4 };

/// The live Unicorn machine and exception controller outlive every hook.
pub const Trap = struct {
    core: *engine.Engine,
    controller: *nvic.Nvic,
    raised: u32 = 0,

    /// Bind the live machine and controller, then hook every divide site.
    pub fn arm(self: *Trap, core: *engine.Engine, controller: *nvic.Nvic, image: elf.Image) Error!usize {
        self.* = .{ .core = core, .controller = controller };
        return attach(core.handle, image, self);
    }
};

/// Recognize a legal 32-bit SDIV or UDIV encoding.
pub fn decode(hw1: u16, hw2: u16) ?Operands {
    const instr: Instr = .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = @intCast(width) };
    if (divide.group.decode(instr) == null) return null;
    const f = divide.fields(instr);
    return .{ .rd = f.rd, .rn = f.rn, .rm = f.rm };
}

/// Hook each divide encoding in executable image segments.
pub fn attach(handle: ?*c.uc.uc_engine, image: elf.Image, trap: *Trap) Error!usize {
    var hooked: usize = 0;
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        if (!segment.executable()) continue;
        var at: usize = 0;
        while (at + width <= segment.bytes.len and hooked < sites_limit) : (at += 2) {
            const hw1 = std.mem.readInt(u16, segment.bytes[at..][0..2], .little);
            const hw2 = std.mem.readInt(u16, segment.bytes[at + 2 ..][0..2], .little);
            if (decode(hw1, hw2) == null) continue;
            try hookAt(handle, segment.vaddr +% @as(u32, @intCast(at)), trap);
            hooked += 1;
        }
    }
    return hooked;
}

/// Hook one address; public for a focused live-Unicorn test.
pub fn hookAt(handle: ?*c.uc.uc_engine, address: u32, trap: *Trap) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_CODE,
        @constCast(@as(*const anyopaque, @ptrCast(&onCode))),
        trap,
        address,
        address,
    ) != c.uc.UC_ERR_OK) return Error.AttachFailed;
}

fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    _ = size;
    const trap: *Trap = @ptrCast(@alignCast(user orelse return));
    const handle = uc orelse return;
    const at: u32 = @truncate(address);
    var bytes: [width]u8 = undefined;
    if (c.uc.uc_mem_read(handle, at, &bytes, bytes.len) != c.uc.UC_ERR_OK) return;
    const operands = decode(
        std.mem.readInt(u16, bytes[0..2], .little),
        std.mem.readInt(u16, bytes[2..4], .little),
    ) orelse return;
    if (!conditionPasses(trap.core)) return;
    if (!trapEnabled(trap.core)) return;
    const divisor = reg(trap.core, operands.rm) orelse return;
    if (divisor != 0) return;
    raise(trap, at) catch return;
}

fn conditionPasses(core: *engine.Engine) bool {
    const xpsr = core.register(.xpsr) catch return false;
    const state = it_state.get(xpsr);
    return !it_state.active(state) or cond.passed(it_state.condition(state), xpsr);
}

fn trapEnabled(core: *engine.Engine) bool {
    return (core.readWord(memmap.scb.ccr) catch 0) & div_0_trp != 0;
}

fn raise(trap: *Trap, address: u32) anyerror!void {
    const core = trap.core;
    const cfsr = try core.readWord(memmap.scb.cfsr);
    try core.writeWord(memmap.scb.cfsr, cfsr | fault_status.Cause.divbyzero.bit());
    const shcsr = try core.readWord(memmap.scb.shcsr);
    const shpr1 = try core.readWord(memmap.scb.shpr1);
    const route = fault_route.route(.usage_fault, shcsr, shpr1, trap.controller.running());
    if (route.escalated) {
        const hfsr = try core.readWord(memmap.scb.hfsr);
        try core.writeWord(memmap.scb.hfsr, hfsr | fault_status.Hard.forced.bit());
    }
    try core.setRegister(.pc, address);
    try trap.controller.enter(core, .{ .number = route.number, .priority = route.priority });
    const xpsr = try core.register(.xpsr);
    try core.setRegister(.xpsr, xpsr & ~it_bits);
    try core.setRegister(.pc, (try core.register(.pc)) | 1);
    trap.raised +%= 1;
}

fn reg(core: *engine.Engine, index: u4) ?u32 {
    const ids = [_]engine.Cortex{
        .r0, .r1, .r2, .r3,  .r4,  .r5,  .r6,
        .r7, .r8, .r9, .r10, .r11, .r12,
    };
    if (index >= ids.len) return null;
    return core.register(ids[index]) catch null;
}
