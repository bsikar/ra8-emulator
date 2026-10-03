//! Unicorn's invalid-instruction hook, wired to CLRM.
//!
//! src/core/clrm.zig decodes the register list; this file reads the encoding
//! out of the core and writes the zeros back. It is a hook of its own beside
//! src/core/csel_hook.zig and src/core/lob_hook.zig: Unicorn walks every
//! UC_HOOK_INSN_INVALID hook in turn and stops at the first that answers
//! true, so this one only has to refuse what is not CLRM.
const std = @import("std");
const c = @import("c.zig");
const clrm = @import("clrm.zig");

pub const Error = error{AttachFailed};

pub fn attach(handle: ?*c.uc.uc_engine, clears: *clrm.Clears) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_INSN_INVALID,
        @constCast(@as(*const anyopaque, @ptrCast(&onInvalidInstruction))),
        clears,
        1,
        0,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

fn onInvalidInstruction(uc: ?*c.uc.uc_engine, user: ?*anyopaque) callconv(.C) bool {
    const clears: *clrm.Clears = @ptrCast(@alignCast(user.?));
    const handle = uc orelse return false;
    const pc = readRegister(handle, c.uc.UC_ARM_REG_PC) orelse return false;
    var bytes: [clrm.width]u8 = undefined;
    if (c.uc.uc_mem_read(handle, pc, &bytes, bytes.len) != c.uc.UC_ERR_OK) return false;
    const instruction = clrm.decode(
        std.mem.readInt(u16, bytes[0..2], .little),
        std.mem.readInt(u16, bytes[2..4], .little),
    ) orelse return false;

    var index: u5 = 0;
    while (index < 15) : (index += 1) {
        const which: u4 = @intCast(index);
        if (instruction.clears(which) and !writeRegister(handle, generalRegister(which), 0)) return false;
    }
    if (instruction.apsr) {
        const apsr = readRegister(handle, c.uc.UC_ARM_REG_APSR) orelse return false;
        if (!writeRegister(handle, c.uc.UC_ARM_REG_APSR, clrm.clearedApsr(apsr))) return false;
    }
    if (!writeRegister(handle, c.uc.UC_ARM_REG_PC, pc + clrm.width | 1)) return false;
    clears.stepped += 1;
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

/// Unicorn's register ids are not contiguous across R0..R12.
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
