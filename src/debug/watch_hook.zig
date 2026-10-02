//! Unicorn's memory-write hook, narrowed to one watched word.
//!
//! src/debug/watch_link.zig matches a store against the stop machine's
//! watch table and records it. This file is the other half: it asks to be
//! called for writes inside the watched window and nowhere else, reads the
//! program counter and link register out of the core, and hands all of it
//! to the link.
//!
//! The range is four bytes, so the cost falls on the stores that reach
//! them rather than on every store the run makes.
const std = @import("std");
const c = @import("../core/c.zig");
const watch_link = @import("watch_link.zig");
const watchpoint = @import("watchpoint.zig");

pub const Error = error{AttachFailed};

/// Install the hook. The link has to outlive the engine, which keeps its
/// pointer for every later run, so it is allocated here and left for the
/// process to reclaim; a run attaches at most one watch.
pub fn attach(handle: ?*c.uc.uc_engine, watched: *watchpoint.Watched) Error!void {
    const owned = std.heap.page_allocator.create(watch_link.Link) catch return Error.AttachFailed;
    owned.* = watch_link.link(watched);
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_MEM_WRITE,
        @constCast(@as(*const anyopaque, @ptrCast(&onWrite))),
        owned,
        watched.address,
        watched.end(),
    ) != c.uc.UC_ERR_OK) {
        std.heap.page_allocator.destroy(owned);
        return Error.AttachFailed;
    }
}

/// Called as the store happens. The program counter still names the
/// storing instruction here, which is the whole point: after it retires
/// the pc has moved on and the answer is gone.
fn onWrite(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = kind;
    const owned: *watch_link.Link = @ptrCast(@alignCast(user orelse return));
    const handle = uc orelse return;
    var pc: u32 = 0;
    if (c.uc.uc_reg_read(handle, c.uc.UC_ARM_REG_PC, &pc) != c.uc.UC_ERR_OK) pc = 0;
    var lr: u32 = 0;
    if (c.uc.uc_reg_read(handle, c.uc.UC_ARM_REG_LR, &lr) != c.uc.UC_ERR_OK) lr = 0;
    owned.store(
        pc,
        lr,
        @truncate(address),
        @intCast(size),
        @truncate(@as(u64, @bitCast(value))),
    );
}
