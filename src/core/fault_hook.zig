//! The store hook over CFSR and HFSR that feeds src/periph/fault_clear.zig.
//!
//! It only latches. The clear is applied at the chunk boundary, because a
//! write hook runs before the store lands and anything it wrote to the word
//! would be overwritten by the store itself.

const c = @import("c.zig");
const memmap = @import("memmap.zig");
const fault_clear = @import("../periph/fault_clear.zig");

pub const Error = error{AttachFailed};

pub fn attach(handle: ?*c.uc.uc_engine, clears: *fault_clear.Clears) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_MEM_WRITE,
        @constCast(@as(*const anyopaque, @ptrCast(&onWrite))),
        clears,
        memmap.scb.cfsr,
        memmap.scb.hfsr + 3,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

fn onWrite(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = kind;
    const clears: *fault_clear.Clears = @ptrCast(@alignCast(user orelse return));
    const handle = uc orelse return;
    const at: u32 = @truncate(address);
    var standing: u32 = 0;
    if (c.uc.uc_mem_read(handle, at & ~@as(u32, 3), &standing, @sizeOf(u32)) != c.uc.UC_ERR_OK) return;
    const written: u32 = @truncate(@as(u64, @bitCast(value)));
    clears.record(at, @intCast(size), written, standing);
}
