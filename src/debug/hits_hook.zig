//! Unicorn's code hook, narrowed to the instructions a run asked to count.
//!
//! src/debug/pc_hits.zig knows what a count means and nothing about
//! Unicorn. This file is the other half: it asks to be called on each
//! requested address and nowhere else, and counts the arrival.
//!
//! One hook per address, with begin and end the same, so the cost falls on
//! the blocks that contain those instructions rather than on every block
//! the run translates. Nothing is ever stopped here: this counter must not
//! change how far a run gets, or the number it reports would be a number
//! about itself.
const c = @import("../core/c.zig");
const pc_hits = @import("pc_hits.zig");

pub const Error = error{AttachFailed};

pub fn attach(handle: ?*c.uc.uc_engine, hits: *pc_hits.Hits) Error!void {
    for (hits.asked()) |one| {
        var hook: c.uc.uc_hook = 0;
        if (c.uc.uc_hook_add(
            handle,
            &hook,
            c.uc.UC_HOOK_CODE,
            @constCast(@as(*const anyopaque, @ptrCast(&onCode))),
            hits,
            one.at,
            one.at,
        ) != c.uc.UC_ERR_OK) {
            return Error.AttachFailed;
        }
    }
}

/// Called before the instruction runs. The address comes from Unicorn
/// rather than from a register read, so a run counting several addresses
/// tells them apart without a second call into the engine.
fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    _ = uc;
    _ = size;
    const hits: *pc_hits.Hits = @ptrCast(@alignCast(user orelse return));
    hits.hit(@truncate(address));
}
