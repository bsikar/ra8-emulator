//! A served session's prefetch (row 23): when the session keeps its
//! history on disk, the application opens a pool sized from the host RAM
//! budget, attaches it to the session, hooks it to the transport so a
//! seek loads the checkpoints near its target ahead of time, and lets the
//! history bridge take a loaded snapshot instead of reading it again.
//! A RAM-only history has nothing to load ahead, so it gets no pool.
const std = @import("std");
const history_resources = @import("ra8_host").history.resources;
const history_storage = @import("ra8_host").history.storage;
const pool_mod = @import("prefetch_pool.zig");
const hook_mod = @import("prefetch_hook.zig");
const served_setup = @import("served_setup.zig");

/// The pool and the transport hook that drives it.
pub const Wired = struct {
    pool: *pool_mod.Pool,
    hook: hook_mod.Hook,
};

/// Opens the pool for a disk-backed history and binds it everywhere it is
/// read; a session without one is left as it was. Call after the bridge
/// is bound.
pub fn attach(self: *served_setup.Served, ram_budget: ?u64) !void {
    const bind = self.history orelse return;
    const budget = try history_resources.ramBudget(ram_budget);
    const store = history_storage.Store.from(&bind.session);
    const pool = try pool_mod.Pool.open(self.gpa, self.io, budget, store);
    errdefer pool.close();
    const wired = try self.gpa.create(Wired);
    const session = self.owner.session();
    wired.* = .{ .pool = pool, .hook = .{ .pool = pool, .session = session } };
    self.prefetch = wired;
    session.attachPrefetch(&pool.state);
    self.context.transport.?.hook = wired.hook.hook();
    if (self.bridge) |*bridge| bridge.prefetched = pool;
}

/// Unbinds and closes the pool, joining its workers; call before the
/// history they read from closes.
pub fn detach(self: *served_setup.Served) void {
    const wired = self.prefetch orelse return;
    self.prefetch = null;
    if (self.context.transport) |t| t.hook = null;
    if (self.bridge) |*bridge| bridge.prefetched = null;
    self.owner.session().prefetch_pool = null;
    wired.pool.close();
    self.gpa.destroy(wired);
}
