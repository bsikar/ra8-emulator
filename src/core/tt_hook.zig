//! Unicorn's code hook, pointed at every TT in the image.
//!
//! src/core/tt.zig builds the response from the board's SAU and knows
//! nothing about Unicorn. This file is the other half. TT is a valid
//! instruction to the CPU model, so the invalid-instruction hook never sees
//! it; the CPU model would answer from an SAU nobody programs and call every
//! address Secure. Instead every place in an executable segment whose bytes
//! decode as TT gets a code hook one instruction wide, which writes the
//! board's answer into Rd and moves the PC past the encoding.
//!
//! Every halfword offset is tried, because a hook on data, or on the
//! second half of another instruction, never fires. The hook re-reads the live bytes before it
//! acts. Inside an IT block, and for TTA from the Non-secure state (which
//! is UNDEFINED), it declines and the CPU model runs the encoding.
const std = @import("std");
const c = @import("c.zig");
const elf = @import("elf.zig");
const sau = @import("../periph/sau.zig");
pub const tt = @import("tt.zig");

pub const Error = error{AttachFailed};

pub const limits = struct {
    /// Hooks one image may take. A CMSE image carries a handful.
    pub const sites: usize = 256;
    /// ITSTATE in the xPSR: bits [26:25] and [15:10].
    pub const it_bits: u32 = 0x0600_FC00;
};

/// Hook every TT in the image's executable segments, answering from
/// `unit`. Returns how many sites were hooked.
pub fn attach(handle: ?*c.uc.uc_engine, image: elf.Image, unit: *const sau.Sau) Error!usize {
    var hooked: usize = 0;
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        if (!segment.executable()) continue;
        var at: usize = 0;
        while (at + tt.width <= segment.bytes.len and hooked < limits.sites) : (at += 2) {
            const first = std.mem.readInt(u16, segment.bytes[at..][0..2], .little);
            const second = std.mem.readInt(u16, segment.bytes[at + 2 ..][0..2], .little);
            if (tt.decode(first, second) == null) continue;
            try hookAt(handle, segment.vaddr +% @as(u32, @intCast(at)), unit);
            hooked += 1;
        }
    }
    return hooked;
}

/// Hook one address. Public so a test can point it at bytes it wrote.
pub fn hookAt(handle: ?*c.uc.uc_engine, address: u32, unit: *const sau.Sau) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_CODE,
        @constCast(@as(*const anyopaque, @ptrCast(&onCode))),
        @constCast(@as(*const anyopaque, @ptrCast(unit))),
        address,
        address,
    ) != c.uc.UC_ERR_OK) return Error.AttachFailed;
}

/// Called before the instruction at a hooked address runs.
fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    _ = size;
    const handle = uc orelse return;
    const unit: *const sau.Sau = @ptrCast(@alignCast(user orelse return));
    const at: u32 = @truncate(address);
    var bytes: [tt.width]u8 = undefined;
    if (c.uc.uc_mem_read(handle, at, &bytes, bytes.len) != c.uc.UC_ERR_OK) return;
    const form = tt.decode(
        std.mem.readInt(u16, bytes[0..2], .little),
        std.mem.readInt(u16, bytes[2..4], .little),
    ) orelse return;
    const xpsr = readRegister(handle, c.uc.UC_ARM_REG_XPSR) orelse return;
    if (xpsr & limits.it_bits != 0) return;
    const secure = tt.executingSecure(unit, at);
    if (form.alternate and !secure) return;
    const target = readRegister(handle, general(form.rn)) orelse return;
    writeRegister(handle, general(form.rd), tt.respond(unit, target, secure));
    // Moving the PC from a code hook ends the block and resumes there, so
    // the CPU model's own TT never runs. The Thumb bit rides along.
    writeRegister(handle, c.uc.UC_ARM_REG_PC, (at + tt.width) | 1);
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
