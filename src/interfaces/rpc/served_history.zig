//! History and choke point attachments for a served session (time-travel
//! design section 11).
//!
//! Attaches the router and branches.bin's sink, the opened image's frozen
//! root and identity, the new-history hook for program reloads, the bounded
//! queue for host traffic during rewinds, the C6 hold, and console stdin
//! routing through the fork router choke point.
const std = @import("std");
const history = @import("ra8_host").history;
const session_api = @import("ra8_session").api;
const session_branch = @import("ra8_session").history_branch;
const session_fork = @import("ra8_session").history_fork_router;
const session_async = @import("ra8_session").history_async_queue;
const session_async_traffic = @import("ra8_session").history_async_traffic;
const history_root = @import("ra8_session").history_root;
const cpu1_bringup = @import("ra8_session").cpu1.bringup;
const served_setup = @import("served_setup.zig");

/// Binds the recording session's lines: router, graph sink, image root,
/// identities, new-history hook, bounded async queue, C6 hold, and console stdin.
pub fn attach(self: *served_setup.Served, allocator: std.mem.Allocator) !void {
    if (self.history == null and self.ram_history == null) return;
    const session = self.owner.session();
    self.root = .{
        .snapshot_version = 1,
        .elf0 = .{
            .identity = history_root.identity(self.owner.image().bytes),
            .bytes = self.owner.image().bytes,
        },
    };
    session.attachRoot(&self.root);
    session.attachImageIdentity(.cpu0, self.root.elf0.identity);
    session.attachNewHistory(.{ .context = self, .startFn = handleNewHistory });
    session.attachAsyncQueue(session_async.AsyncQueue.init(allocator, 0));
    self.owner.board().c6.wire.bridge.hold = .{ .context = session, .heldFn = hostHeld };
    self.owner.board().console_input.hook = .{ .context = session, .feedFn = routeConsoleStdin };

    if (self.history) |b| {
        session.attachForkRouter(&b.router);
        session.attachGraphSink(b.graph_sink);
        if (b.root == null) {
            b.root = self.root;
            saveRoot(self.io, b.session.dir, allocator, &self.root) catch {};
        }
    } else {
        const graph = try allocator.create(session_branch.BranchGraph);
        errdefer allocator.destroy(graph);
        graph.* = try session_branch.BranchGraph.init(allocator);
        errdefer graph.deinit();
        const router = try allocator.create(session_fork.ForkRouter);
        errdefer allocator.destroy(router);
        router.* = session_fork.ForkRouter.init(allocator, graph);
        self.ram_graph = graph;
        self.ram_router = router;
        session.attachForkRouter(router);
    }
}

/// When CPU1 is brought up, updates root and identity for core 1.
pub fn attachSecond(self: *served_setup.Served, cpu1: *cpu1_bringup.Cpu1) void {
    if (cpu1.image) |img| {
        self.root.elf1 = .{
            .identity = history_root.identity(img.bytes),
            .bytes = img.bytes,
        };
        self.owner.session().attachImageIdentity(.cpu1, self.root.elf1.?.identity);
    }
}

/// The C6 hold: host traffic waits while the session replays or stands
/// before the active line's recorded end.
pub fn hostHeld(context: *anyopaque) bool {
    const session: *session_api.Session = @ptrCast(@alignCast(context));
    return session.replaying or session_async_traffic.isCursorInPast(session);
}

/// Routes console keystrokes from stdin through the fork router choke point.
pub fn routeConsoleStdin(context: *anyopaque, bytes: []const u8) void {
    const session: *session_api.Session = @ptrCast(@alignCast(context));
    session.consoleInput(.cpu0, bytes) catch {};
}

/// A different program was loaded: marks the old history detached so its
/// branches.bin is never overwritten by the new program's line graph.
pub fn handleNewHistory(context: *anyopaque, core: session_api.Core, image_bytes: []const u8) anyerror!void {
    const self: *served_setup.Served = @ptrCast(@alignCast(context));
    _ = image_bytes;
    _ = core;
    if (self.history) |b| b.detached = true;
}

fn saveRoot(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, r: *const history_root.Root) !void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try history_root.encode(r, &buf.writer);
    const file = try dir.createFile(io, history.layout.files.root, .{ .truncate = true, .resolve_beneath = true });
    defer file.close(io);
    try file.writeStreamingAll(io, buf.written());
    try file.sync(io);
}
