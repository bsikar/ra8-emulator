//! Unicorn's code hook, pointed at each undefined site the sweep found.
//!
//! src/core/undefined_ops.zig knows which encodings the architecture leaves
//! undefined and nothing about Unicorn. This file is the other half: it asks
//! to be called on each swept site's own address and nowhere else, and
//! counts the arrival.
//!
//! One hook per site, each a single instruction wide, so the cost falls on
//! the blocks that actually contain one rather than on every block the run
//! translates. A site that is really a literal pool is never executed and
//! its hook never fires, which is exactly the distinction the count exists
//! to draw.
const c = @import("c.zig");
const undefined_ops = @import("undefined_ops.zig");

pub const Error = error{AttachFailed};

/// Watch every site the sweep kept. The sites live in the caller's `Found`
/// and are written through for the length of the run, so it has to outlive
/// the run: a pointer into a temporary here would count into freed memory.
pub fn attach(handle: ?*c.uc.uc_engine, found: *undefined_ops.Found) Error!void {
    for (found.kept()) |*site| {
        var hook: c.uc.uc_hook = 0;
        if (c.uc.uc_hook_add(
            handle,
            &hook,
            c.uc.UC_HOOK_CODE,
            @constCast(@as(*const anyopaque, @ptrCast(&onCode))),
            site,
            site.address,
            site.address,
        ) != c.uc.UC_ERR_OK) {
            return Error.AttachFailed;
        }
    }
}

/// Called before the instruction at the site runs.
///
/// By default nothing is stopped: the run is allowed to go on doing
/// whatever this core does with an undefined encoding, because the
/// report's job is to say the run cannot be trusted, not to decide that
/// for the reader.
///
/// A site carrying `stop` ends the run here instead, which is what
/// `--stop-on-undefined` asks for. The hook fires BEFORE the instruction
/// executes, so the stop leaves the machine as it stood on the way in and
/// a register or memory dump beside it reads the state that produced the
/// undefined encoding rather than the state after it. The arrival is
/// counted either way, before the stop, so the report never shows a run
/// that stopped at a site with no arrivals at it.
fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    _ = address;
    _ = size;
    const site: *undefined_ops.Site = @ptrCast(@alignCast(user orelse return));
    site.runs +|= 1;
    if (site.stop) _ = c.uc.uc_emu_stop(uc);
}
