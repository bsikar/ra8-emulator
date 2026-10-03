//! Unicorn's writes for one lockstep instruction, captured before they land.
const c = @import("../../c.zig");
const writes = @import("writes.zig");

pub const Hook = struct {
    handle: ?*c.uc.uc_engine,
    hook: c.uc.uc_hook,
    recorder: writes.Recorder,

    pub fn attach(self: *Hook) error{AttachFailed}!void {
        if (c.uc.uc_hook_add(self.handle, &self.hook, c.uc.UC_HOOK_MEM_WRITE, @constCast(@as(*const anyopaque, @ptrCast(&onWrite))), &self.recorder, 0, 0xFFFF_FFFF) != c.uc.UC_ERR_OK) {
            return error.AttachFailed;
        }
    }

    pub fn detach(self: *Hook) void {
        if (self.hook != 0) _ = c.uc.uc_hook_del(self.handle, self.hook);
        self.hook = 0;
    }
};

fn onWrite(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = uc;
    _ = kind;
    const recorder: *writes.Recorder = @ptrCast(@alignCast(user orelse return));
    if (size <= 0 or size > writes.widest) return;
    const carried: u64 = @bitCast(value);
    var bytes: [writes.widest]u8 = undefined;
    for (0..@intCast(size)) |i| bytes[i] = @truncate(carried >> @intCast(i * 8));
    recorder.record(@truncate(address), bytes[0..@intCast(size)]);
}
