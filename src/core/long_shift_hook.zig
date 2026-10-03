//! Unicorn's code hook, pointed at every long shift in the image.
//!
//! src/core/long_shift.zig knows what the long shifts mean and nothing about
//! Unicorn. This file is the other half. The encodings are not invalid to
//! the CPU model, which runs them as ORRS with PC or SP, so the invalid-
//! instruction hook that carries CSEL never sees them. Instead every place
//! in an executable segment whose bytes decode as a long shift gets a code
//! hook one instruction wide; the hook runs the Armv8.1-M result and moves
//! the PC past the encoding, so the CPU model's ORRS never executes.
//!
//! Every halfword offset is tried, not a stepped walk: a hook on bytes that
//! are really data, or the second half of another instruction, never fires,
//! and a stepped walk can lose its footing in a literal pool and miss a real
//! one. The hook re-reads and re-decodes the live bytes, so a hooked address
//! that holds something else by the time it runs is left alone.
//!
//! Inside an IT block the hook declines and the CPU model runs the encoding
//! as it always has: honouring the condition and advancing ITSTATE by hand
//! is not done here. Lockstep shows such a site as a divergence.
const std = @import("std");
const c = @import("c.zig");
const elf = @import("elf.zig");
pub const long_shift = @import("long_shift.zig");

pub const Error = error{AttachFailed};

pub const limits = struct {
    /// Hooks one image may take. Real images carry tens; the cap is there
    /// so a data segment marked executable cannot add thousands.
    pub const sites: usize = 4096;
    /// ITSTATE in the xPSR: bits [26:25] and [15:10].
    pub const it_bits: u32 = 0x0600_FC00;
    pub const q_bit: u32 = 1 << 27;
};

/// Hook every long shift in the image's executable segments. Returns how
/// many sites were hooked.
pub fn attach(handle: ?*c.uc.uc_engine, image: elf.Image) Error!usize {
    var hooked: usize = 0;
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        if (!segment.executable()) continue;
        var at: usize = 0;
        while (at + long_shift.width <= segment.bytes.len and hooked < limits.sites) : (at += 2) {
            const first = std.mem.readInt(u16, segment.bytes[at..][0..2], .little);
            const second = std.mem.readInt(u16, segment.bytes[at + 2 ..][0..2], .little);
            if (long_shift.decode(first, second) == null) continue;
            try hookAt(handle, segment.vaddr +% @as(u32, @intCast(at)));
            hooked += 1;
        }
    }
    return hooked;
}

/// Hook one address. Public so a test can point it at bytes it wrote.
pub fn hookAt(handle: ?*c.uc.uc_engine, address: u32) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_CODE,
        @constCast(@as(*const anyopaque, @ptrCast(&onCode))),
        null,
        address,
        address,
    ) != c.uc.UC_ERR_OK) return Error.AttachFailed;
}

/// Called before the instruction at a hooked address runs.
fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    _ = size;
    _ = user;
    const handle = uc orelse return;
    const at: u32 = @truncate(address);
    var bytes: [long_shift.width]u8 = undefined;
    if (c.uc.uc_mem_read(handle, at, &bytes, bytes.len) != c.uc.UC_ERR_OK) return;
    const form = long_shift.decode(
        std.mem.readInt(u16, bytes[0..2], .little),
        std.mem.readInt(u16, bytes[2..4], .little),
    ) orelse return;
    const xpsr = readRegister(handle, c.uc.UC_ARM_REG_XPSR) orelse return;
    if (xpsr & limits.it_bits != 0) return;

    var regs: long_shift.Regs = undefined;
    for (&regs, 0..) |*slot, i| slot.* = readRegister(handle, general(@intCast(i))) orelse return;
    const before = regs;
    const saturated = long_shift.run(form, &regs);
    for (regs, before, 0..) |now, was, i| {
        if (now != was) writeRegister(handle, general(@intCast(i)), now);
    }
    if (saturated) {
        const apsr = readRegister(handle, c.uc.UC_ARM_REG_APSR) orelse return;
        writeRegister(handle, c.uc.UC_ARM_REG_APSR, apsr | limits.q_bit);
    }
    // Moving the PC from a code hook ends the block and resumes there, so
    // the CPU model's ORRS never runs. The Thumb bit rides along.
    writeRegister(handle, c.uc.UC_ARM_REG_PC, (at + long_shift.width) | 1);
}

fn readRegister(handle: ?*c.uc.uc_engine, which: c_int) ?u32 {
    var value: u32 = 0;
    if (c.uc.uc_reg_read(handle, which, &value) != c.uc.UC_ERR_OK) return null;
    return value;
}

fn writeRegister(handle: ?*c.uc.uc_engine, which: c_int, value: u32) void {
    var scratch = value;
    _ = c.uc.uc_reg_write(handle, which, &scratch);
}

/// Unicorn's ids for R0 to R14 are not contiguous, so this is a table.
fn general(index: u4) c_int {
    const ids = [_]c_int{
        c.uc.UC_ARM_REG_R0,  c.uc.UC_ARM_REG_R1,  c.uc.UC_ARM_REG_R2,
        c.uc.UC_ARM_REG_R3,  c.uc.UC_ARM_REG_R4,  c.uc.UC_ARM_REG_R5,
        c.uc.UC_ARM_REG_R6,  c.uc.UC_ARM_REG_R7,  c.uc.UC_ARM_REG_R8,
        c.uc.UC_ARM_REG_R9,  c.uc.UC_ARM_REG_R10, c.uc.UC_ARM_REG_R11,
        c.uc.UC_ARM_REG_R12, c.uc.UC_ARM_REG_SP,  c.uc.UC_ARM_REG_LR,
    };
    return ids[index];
}
