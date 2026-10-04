//! Unicorn's code hook, pointed at every VSCCLRM in the image (RA8EMU-372).
//!
//! The pinned Unicorn has no Armv8.1-M model. VSCCLRM sits in the VLDMIA
//! space with Rn = PC, so the CPU model runs it as a load from the literal
//! pool and, being an FP instruction in the Secure state, opens a Secure FP
//! context and sets CONTROL.SFPA. The real instruction is a NOP when
//! FPCCR.ASPEN is set and SFPA is clear, and otherwise zeroes its run of
//! registers. The Zig core does the same (src/core/cpu/ops/vscclrm.zig).
//!
//! Like src/core/fp_context.zig, ASPEN is taken as its reset value 1, since
//! the Unicorn backend cannot see FPCCR, and a fresh context's FPSCR as
//! FPDSCR's reset value 0. VPR has no Unicorn register and is left alone.
//! Every halfword offset of an executable segment is tried; the hook
//! re-reads the live bytes and declines inside an IT block.
const std = @import("std");
const c = @import("c.zig");
const elf = @import("elf.zig");
const fp_context = @import("fp_context.zig");
const decoder = @import("cpu/ops/vscclrm.zig");
const Instr = @import("cpu/instr.zig").Instr;

pub const Error = error{AttachFailed};

pub const width: u32 = 4;

pub const limits = struct {
    /// Hooks one image may take. A CMSE image carries one per entry veneer.
    pub const sites: usize = 256;
    /// ITSTATE in the xPSR: bits [26:25] and [15:10].
    pub const it_bits: u32 = 0x0600_FC00;
};

/// The run of S registers an encoding clears, or null when it is not one.
pub fn decode(hw1: u16, hw2: u16) ?decoder.Run {
    return decoder.run(Instr{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = width });
}

/// Hook every VSCCLRM in the image's executable segments. Returns how many
/// sites were hooked.
pub fn attach(handle: ?*c.uc.uc_engine, image: elf.Image) Error!usize {
    var hooked: usize = 0;
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        if (!segment.executable()) continue;
        var at: usize = 0;
        while (at + width <= segment.bytes.len and hooked < limits.sites) : (at += 2) {
            const first = std.mem.readInt(u16, segment.bytes[at..][0..2], .little);
            const second = std.mem.readInt(u16, segment.bytes[at + 2 ..][0..2], .little);
            if (decode(first, second) == null) continue;
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
    var bytes: [width]u8 = undefined;
    if (c.uc.uc_mem_read(handle, at, &bytes, bytes.len) != c.uc.UC_ERR_OK) return;
    const run = decode(
        std.mem.readInt(u16, bytes[0..2], .little),
        std.mem.readInt(u16, bytes[2..4], .little),
    ) orelse return;
    const xpsr = readRegister(handle, c.uc.UC_ARM_REG_XPSR) orelse return;
    if (xpsr & limits.it_bits != 0) return;
    const control = readRegister(handle, c.uc.UC_ARM_REG_CONTROL) orelse return;
    if (control & fp_context.control_sfpa != 0) clear(handle, control, run);
    // Moving the PC from a code hook ends the block and resumes there, so
    // the CPU model's own reading of the encoding never runs.
    writeRegister(handle, c.uc.UC_ARM_REG_PC, (at + width) | 1);
}

/// ExecuteFPCheck's context creation, then the zeros.
fn clear(handle: *c.uc.uc_engine, control: u32, run: decoder.Run) void {
    if (control & fp_context.control_fpca == 0) {
        writeRegister(handle, c.uc.UC_ARM_REG_FPSCR, fp_context.default_fpscr);
        writeRegister(handle, c.uc.UC_ARM_REG_CONTROL, control | fp_context.control_fpca);
    }
    var i: u32 = 0;
    while (i < run.count) : (i += 1) {
        writeRegister(handle, c.uc.UC_ARM_REG_S0 + @as(c_int, @intCast(run.first + i)), 0);
    }
}

fn readRegister(handle: *c.uc.uc_engine, which: c_int) ?u32 {
    var value: u32 = 0;
    if (c.uc.uc_reg_read(handle, which, &value) != c.uc.UC_ERR_OK) return null;
    return value;
}

fn writeRegister(handle: *c.uc.uc_engine, which: c_int, value: u32) void {
    var scratch = value;
    _ = c.uc.uc_reg_write(handle, which, &scratch);
}
