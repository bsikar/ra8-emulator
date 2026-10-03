//! Optional Unicorn instruction hook feeding the function profile table.
const c = @import("../core/c.zig");
const profile = @import("profile.zig");

pub const Error = error{AttachFailed};

pub fn attach(handle: ?*c.uc.uc_engine, table: *profile.Table) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(handle, &hook, c.uc.UC_HOOK_CODE, @constCast(@as(*const anyopaque, @ptrCast(&onCode))), table, 1, 0) != c.uc.UC_ERR_OK) return Error.AttachFailed;
}

fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    _ = uc;
    _ = size;
    const table: *profile.Table = @ptrCast(@alignCast(user orelse return));
    table.instruction(@truncate(address));
}
