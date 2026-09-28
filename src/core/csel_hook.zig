//! Unicorn's invalid-instruction hook, wired to the conditional selects.
//!
//! src/core/csel.zig knows what CSEL, CSINC, CSINV and CSNEG mean and nothing
//! about Unicorn. This file is the other half: it reads the encoding and the
//! flags out of the core, asks csel.zig what lands where, and writes the
//! answer back. Keeping the two apart is what lets the semantics be tested
//! without a live engine.
//!
//! This is a SECOND hook of the same kind as src/core/lob_hook.zig, not a
//! replacement for it. Unicorn walks every UC_HOOK_INSN_INVALID hook in turn
//! and stops at the first that answers true, so each one only has to refuse
//! what is not its own encoding, and the two stay independent.
const std = @import("std");
const c = @import("c.zig");
const csel = @import("csel.zig");

pub const Error = error{AttachFailed};

pub fn attach(handle: ?*c.uc.uc_engine, selects: *csel.Selects) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_INSN_INVALID,
        @constCast(@as(*const anyopaque, @ptrCast(&onInvalidInstruction))),
        selects,
        1,
        0,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

/// Returning true tells Unicorn the encoding was handled, and it resumes from
/// the PC this leaves behind; returning false leaves the encoding to the next
/// hook, and to the fault it should be when no hook owns it.
fn onInvalidInstruction(uc: ?*c.uc.uc_engine, user: ?*anyopaque) callconv(.C) bool {
    const selects: *csel.Selects = @ptrCast(@alignCast(user.?));
    const handle = uc orelse return false;
    const pc = readRegister(handle, c.uc.UC_ARM_REG_PC) orelse return false;
    var bytes: [csel.encoding.width]u8 = undefined;
    if (c.uc.uc_mem_read(handle, pc, &bytes, bytes.len) != c.uc.UC_ERR_OK) return false;
    const instruction = csel.decode(
        std.mem.readInt(u16, bytes[0..2], .little),
        std.mem.readInt(u16, bytes[2..4], .little),
    ) orelse return false;

    const apsr = readRegister(handle, c.uc.UC_ARM_REG_APSR) orelse return false;
    const then_value = sourceValue(handle, instruction.then_source) orelse return false;
    const else_value = sourceValue(handle, instruction.else_source) orelse return false;
    const result = csel.select(instruction, apsr, then_value, else_value);
    if (!writeRegister(handle, generalRegister(instruction.destination), result)) return false;

    // The Thumb bit rides along: a PC written without it can put the core
    // into an A32 state the RA8D2 does not have. Neither the flags nor any
    // other register moves, because none of the four has an S variant.
    if (!writeRegister(handle, c.uc.UC_ARM_REG_PC, pc + csel.encoding.width | 1)) return false;
    selects.stepped += 1;
    return true;
}

/// Register 0b1111 in a source field is the zero register, so it is read here
/// rather than out of the core, where that number means the PC.
fn sourceValue(handle: ?*c.uc.uc_engine, which: u4) ?u32 {
    if (which == csel.encoding.zero_register) return 0;
    return readRegister(handle, generalRegister(which));
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
