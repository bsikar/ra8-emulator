//! A different image starts a new history (time-travel design section 11).
//!
//! The old history's lines describe another program's run, so loading a
//! different image never forks from them and is never refused: the session
//! drops its lines back to a fresh base line, asks the application to open
//! a new history if it bound a hook for that, and loads the image live. A
//! session that records into a persistent history but has no such hook
//! stops recording rather than mixing two programs into one history.
const std = @import("std");
const api = @import("api.zig");
const fork = @import("fork.zig");
const branch_mod = @import("history/branch.zig");
const history_root = @import("history/root.zig");
const async_traffic = @import("history/async_traffic.zig");

const Session = api.Session;
const Core = api.Core;

/// Whether `image` is a different program from the one this session's
/// history recorded for `core`. A session with no history has nothing to
/// differ from.
pub fn differs(self: *const Session, core: Core, image: []const u8) bool {
    const id = history_root.identity(image);
    if (self.root) |root| {
        const expected = switch (core) {
            .cpu0 => root.elf0.identity,
            .cpu1 => if (root.elf1) |elf1| elf1.identity else return true,
        };
        return !std.mem.eql(u8, &expected, &id);
    }
    if (self.fork_router == null) return false;
    const seen = self.image_identity[@backingInt(core)] orelse return false;
    return !std.mem.eql(u8, &seen, &id);
}

/// Starts a new history for `image` on `core` and loads it live.
pub fn start(self: *Session, core: Core, image: []const u8) anyerror!void {
    try resetLines(self);
    self.root = null;
    self.image_identity = .{ null, null };
    self.image_identity[@backingInt(core)] = history_root.identity(image);
    if (self.new_history) |hook| {
        try hook.startFn(hook.context, core, image);
    } else if (self.persistent_recorder != null) {
        self.persistent_recorder = null;
    }
    try fork.applyAction(self, .{ .load = .{ .core = core, .image = image } });
}

/// Back to a single base line: no branches, no pending fork, nothing queued.
fn resetLines(self: *Session) !void {
    _ = async_traffic.clearOnFork(self);
    const router = self.fork_router orelse return;
    router.cancel();
    router.first_fork_confirmed = false;
    router.seq = 0;
    if (router.graph) |graph| {
        const allocator = graph.allocator;
        graph.deinit();
        graph.* = try branch_mod.BranchGraph.init(allocator);
    }
    router.switchActiveLine(branch_mod.root_branch_id);
}
