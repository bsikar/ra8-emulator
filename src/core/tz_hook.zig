//! Unicorn's code hook at the BLXNS: enter the Non-Secure world by hand.
//!
//! src/core/tz.zig knows what BLXNS means and nothing about Unicorn. This
//! file is the other half: it reads the encoding out of the core, asks
//! tz.zig where the branch goes, writes the answer back, and stops the chunk
//! so the instruction itself never runs.
//!
//! STOPPING IS THE POINT, not a side effect. The hook fires before the
//! instruction, the same moment src/core/break_hook.zig relies on, so
//! stopping here leaves the BLXNS unexecuted and the core in Secure state.
//! The program counter written here is where the next chunk starts, which is
//! how the run carries on into the Non-Secure image rather than ending at
//! it: the engine's run loop reads the program counter at every boundary.
//!
//! The range is a single instruction, so the hook costs the blocks that
//! contain it rather than every block the run translates.
const std = @import("std");
const c = @import("c.zig");
const tz = @import("tz.zig");
const memmap = @import("memmap.zig");

pub const Error = error{AttachFailed};

pub fn attach(handle: ?*c.uc.uc_engine, worlds: *tz.Worlds, at: u32) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_CODE,
        @constCast(@as(*const anyopaque, @ptrCast(&onCode))),
        worlds,
        at,
        at,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
    worlds.armed_at = at;
}

/// Called before the BLXNS runs. Every step can fail, and a failure leaves
/// the core untouched so the instruction runs and faults as it did before:
/// a half-performed switch would be worse than none.
fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    _ = size;
    const worlds: *tz.Worlds = @ptrCast(@alignCast(user orelse return));
    const handle = uc orelse return;
    const site: u32 = @truncate(address);
    const halfword = readHalfword(handle, site) orelse return;
    const which = tz.decode(halfword) orelse return;
    const target = readRegister(handle, generalRegister(which)) orelse return;
    const entry = tz.enter(target, nonSecureStack(handle), site +% tz.encoding.width);
    if (entry.sp) |stack| {
        if (!writeRegister(handle, c.uc.UC_ARM_REG_SP, stack)) return;
    }
    if (!writeRegister(handle, c.uc.UC_ARM_REG_LR, entry.lr)) return;
    if (!writeRegister(handle, c.uc.UC_ARM_REG_PC, entry.pc)) return;
    worlds.record(entry);
    _ = c.uc.uc_emu_stop(handle);
}

/// The stack the Non-Secure world expects, read the way the firmware set it.
///
/// `MSR MSP_NS` has already run by the time the BLXNS is reached, but the
/// pinned Unicorn exposes no banked Non-Secure stack pointer to read it back
/// from, so the value is taken from where the firmware got it: the first
/// word of the Non-Secure vector table, whose base it wrote to VTOR_NS a few
/// instructions earlier. VTOR_NS is plain RAM here, so the write is simply
/// there to be read. Null when it never happened, which leaves the Secure
/// stack in place rather than moving the stack pointer to zero.
fn nonSecureStack(handle: ?*c.uc.uc_engine) ?u32 {
    const base = readWord(handle, memmap.scb.vtor_ns) orelse return null;
    if (base == 0) return null;
    return readWord(handle, base);
}

fn readHalfword(handle: ?*c.uc.uc_engine, address: u32) ?u16 {
    var bytes: [2]u8 = undefined;
    if (c.uc.uc_mem_read(handle, address, &bytes, bytes.len) != c.uc.UC_ERR_OK) return null;
    return std.mem.readInt(u16, &bytes, .little);
}

fn readWord(handle: ?*c.uc.uc_engine, address: u32) ?u32 {
    var bytes: [4]u8 = undefined;
    if (c.uc.uc_mem_read(handle, address, &bytes, bytes.len) != c.uc.UC_ERR_OK) return null;
    return std.mem.readInt(u32, &bytes, .little);
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
/// is a table rather than an addition. BLXNS names one of R0..R14; R15 is
/// not encodable, and the table carries it only so the index is total.
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
