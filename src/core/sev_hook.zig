//! Unicorn's code hook on CPU0, armed only while CPU1 is parked in WFE, so
//! a SEV that CPU0 runs wakes CPU1 (RA8EMU-36).
//!
//! Unicorn runs SEV as a NOP. Nothing stops and nothing reports it, so the
//! only way to see one is to look at every instruction CPU0 runs, and that
//! costs a memory read per instruction. The cost is paid only while CPU1
//! is parked: interleave.zig arms the hook for a CPU0 round when CPU1
//! starts that round parked and disarms it afterwards. Once CPU1 wakes, the
//! callback returns before it reads anything.
//!
//! Arming and disarming flush the translation cache, for the reason
//! src/core/mpu_guard.zig gives: a block translated before the hook went in
//! would otherwise run without it.
const std = @import("std");
const c = @import("c.zig");
const second_wait = @import("second_wait.zig");

pub const sev: u16 = 0xBF40;

pub const Error = error{AttachFailed};

/// uc_ctl's write direction, which the C import loses (see mpu_guard.zig).
const io_write: c_uint = 1;

pub const Armed = struct {
    handle: ?*c.uc.uc_engine,
    hook: c.uc.uc_hook,

    pub fn disarm(self: Armed) void {
        _ = c.uc.uc_hook_del(self.handle, self.hook);
        flush(self.handle);
    }
};

/// Watch CPU0, behind `handle`, for a SEV that wakes `wait`.
pub fn arm(handle: ?*c.uc.uc_engine, wait: *second_wait.Wait) Error!Armed {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_CODE,
        @constCast(@as(*const anyopaque, @ptrCast(&onCode))),
        wait,
        0,
        0xFFFF_FFFF,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
    flush(handle);
    return .{ .handle = handle, .hook = hook };
}

fn flush(handle: ?*c.uc.uc_engine) void {
    const control: c_uint = @as(c_uint, @intCast(c.uc.UC_CTL_TB_FLUSH)) |
        (@as(c_uint, io_write) << 30);
    _ = c.uc.uc_ctl(handle, control);
}

fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    const wait: *second_wait.Wait = @ptrCast(@alignCast(user orelse return));
    if (size != 2 or !wait.parked()) return;
    const handle = uc orelse return;
    var bytes: [2]u8 = undefined;
    if (c.uc.uc_mem_read(handle, address, &bytes, bytes.len) != c.uc.UC_ERR_OK) return;
    if (std.mem.readInt(u16, &bytes, .little) == sev) wait.sev();
}
