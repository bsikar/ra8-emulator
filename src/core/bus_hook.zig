//! Unicorn's invalid-access hook.
//!
//! src/core/fault.zig knows what a bad access looks like once it has been
//! recorded; this file is the Unicorn half that records it, and with
//! src/core/c.zig the only place here that handles a C calling convention or
//! a raw pointer. The peripheral-window half went with RA8EMU-607: the Zig
//! core reaches the bus through src/core/cpu/board_bus.zig. This file goes
//! when the Unicorn run loop does.
const c = @import("c.zig");
const fault = @import("fault.zig");

pub const Error = error{AttachFailed};

/// Record the invalid accesses a run takes. Without this a fault is just an
/// error code and a PC; with it the report can say which address the
/// firmware reached for and how wide the access was.
pub fn attachWatch(handle: ?*c.uc.uc_engine, watch: *fault.Watch) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_MEM_INVALID,
        @constCast(@as(*const anyopaque, @ptrCast(&onInvalid))),
        watch,
        1,
        0,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

fn onInvalid(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) bool {
    _ = uc;
    const watch: *fault.Watch = @ptrCast(@alignCast(user.?));
    watch.last = .{
        .kind = switch (kind) {
            c.uc.UC_MEM_WRITE_UNMAPPED, c.uc.UC_MEM_WRITE_PROT => .write,
            c.uc.UC_MEM_FETCH_UNMAPPED, c.uc.UC_MEM_FETCH_PROT => .fetch,
            else => .read,
        },
        .address = address,
        .size = @intCast(size),
        .value = @bitCast(value),
    };
    // false: do not pretend the access succeeded, let the run stop.
    return false;
}
