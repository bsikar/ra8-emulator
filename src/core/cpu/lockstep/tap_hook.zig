//! Unicorn's side of the peripheral log: memory hooks over both peripheral
//! windows that write each completed read and each write into the log.
//!
//! The MMIO handlers already attached to the window still answer the access;
//! these hooks only watch it, so the oracle's run is unchanged. Like the
//! other hook files, this is a place a C calling convention is handled.
const c = @import("../../c.zig");
const periph = @import("../../../periph/registry.zig");
const periph_log = @import("periph_log.zig");
const bus_hook = @import("../../bus_hook.zig");

pub const Error = error{AttachFailed};

/// One hook per window, so `detach` can remove exactly what was added.
pub const Taps = struct {
    hooks: [2]c.uc.uc_hook = .{ 0, 0 },
};

pub fn attach(handle: ?*c.uc.uc_engine, log: *periph_log.Log) Error!Taps {
    var taps: Taps = .{};
    for ([_]u32{ periph.base, periph.ns_base }, 0..) |window, i| {
        if (c.uc.uc_hook_add(
            handle,
            &taps.hooks[i],
            c.uc.UC_HOOK_MEM_READ_AFTER | c.uc.UC_HOOK_MEM_WRITE,
            @constCast(@as(*const anyopaque, @ptrCast(&onAccess))),
            log,
            window,
            @as(u64, window) + periph.size - 1,
        ) != c.uc.UC_ERR_OK) {
            detach(handle, taps);
            return Error.AttachFailed;
        }
    }
    return taps;
}

pub fn detach(handle: ?*c.uc.uc_engine, taps: Taps) void {
    for (taps.hooks) |hook| {
        if (hook != 0) _ = c.uc.uc_hook_del(handle, hook);
    }
}

fn onAccess(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = uc;
    const log: *periph_log.Log = @ptrCast(@alignCast(user.?));
    const width = bus_hook.widthOf(@intCast(size));
    const access: periph_log.Access = .{
        .address = @truncate(address),
        .width = width,
        .value = mask(@truncate(@as(u64, @bitCast(value))), width),
    };
    if (kind == c.uc.UC_MEM_WRITE) log.noteWrite(access) else log.noteRead(access);
}

/// Only the bytes the access carried; Unicorn may hand back more.
pub fn mask(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}
