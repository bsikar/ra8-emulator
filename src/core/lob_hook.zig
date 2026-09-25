//! Unicorn's invalid-instruction hook, wired to the low-overhead loop
//! stepper.
//!
//! src/core/lob.zig knows what DLS, WLS and LE mean and nothing about
//! Unicorn. This file is the other half: it reads the encoding out of the
//! core, asks lob.zig what it does, and writes the answer back. Keeping the
//! two apart is what lets the semantics be tested without a live engine.
const std = @import("std");
const c = @import("c.zig");
const lob = @import("lob.zig");

pub const Error = error{AttachFailed};

pub fn attach(handle: ?*c.uc.uc_engine, loops: *lob.Loops) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_INSN_INVALID,
        @constCast(@as(*const anyopaque, @ptrCast(&onInvalidInstruction))),
        loops,
        1,
        0,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

/// Returning true tells Unicorn the encoding was handled, and it resumes from
/// the PC this leaves behind; returning false leaves a genuinely undefined
/// instruction the fault it should be.
fn onInvalidInstruction(uc: ?*c.uc.uc_engine, user: ?*anyopaque) callconv(.C) bool {
    const loops: *lob.Loops = @ptrCast(@alignCast(user.?));
    const handle = uc orelse return false;
    const pc = readRegister(handle, c.uc.UC_ARM_REG_PC) orelse return false;
    var bytes: [lob.encoding.width]u8 = undefined;
    if (c.uc.uc_mem_read(handle, pc, &bytes, bytes.len) != c.uc.UC_ERR_OK) return false;
    const instruction = lob.decode(
        std.mem.readInt(u16, bytes[0..2], .little),
        std.mem.readInt(u16, bytes[2..4], .little),
    ) orelse return false;

    const lr = readRegister(handle, c.uc.UC_ARM_REG_LR) orelse return false;
    const source = switch (instruction.kind) {
        .le => lr,
        else => readRegister(handle, generalRegister(instruction.source)) orelse return false,
    };
    const taken = lob.step(instruction, pc, source, lr);
    if (taken.lr) |value| {
        if (!writeRegister(handle, c.uc.UC_ARM_REG_LR, value)) return false;
    }
    // The Thumb bit rides along: a PC written without it can put the core
    // into an A32 state the RA8D2 does not have.
    if (!writeRegister(handle, c.uc.UC_ARM_REG_PC, taken.next_pc | 1)) return false;
    loops.stepped += 1;
    return true;
}

fn readRegister(handle: ?*c.uc.uc_engine, which: c_int) ?u32 {
    var value: u32 = 0;
    if (c.uc.uc_reg_read(handle, which, &value) != c.uc.UC_ERR_OK) return null;
    return value;
}

fn writeRegister(handle: ?*c.uc.uc_engine, which: c_int, value: u32) bool {
    var scratch = value;
    return c.uc.uc_reg_write(handle, which, &scratch) == c.uc.UC_ERR_OK;
}

/// Unicorn's register ids are not contiguous across R0..R12, so the mapping
/// is a table rather than an addition.
fn generalRegister(index: u4) c_int {
    const ids = [_]c_int{
        c.uc.UC_ARM_REG_R0,  c.uc.UC_ARM_REG_R1,  c.uc.UC_ARM_REG_R2,
        c.uc.UC_ARM_REG_R3,  c.uc.UC_ARM_REG_R4,  c.uc.UC_ARM_REG_R5,
        c.uc.UC_ARM_REG_R6,  c.uc.UC_ARM_REG_R7,  c.uc.UC_ARM_REG_R8,
        c.uc.UC_ARM_REG_R9,  c.uc.UC_ARM_REG_R10, c.uc.UC_ARM_REG_R11,
        c.uc.UC_ARM_REG_R12, c.uc.UC_ARM_REG_SP,  c.uc.UC_ARM_REG_LR,
        c.uc.UC_ARM_REG_PC,
    };
    return ids[index];
}
