//! The backend listener outlives its optional firmware session.
const machine = @import("ra8_chip").core.machine;
const resources = @import("session_resources.zig");
const std = @import("std");

const listen = @import("listen.zig");
const loop = @import("loop.zig");
const rpc = @import("ra8_rpc");
const targets = @import("targets.zig");
const Workbench = @import("workbench.zig").Workbench;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    asked: anytype,
    history: ?rpc.served_setup.HistoryOpts,
    comptime attachRuntime: anytype,
) !u8 {
    const Binding = struct {
        asked: @TypeOf(asked),
        io: std.Io,

        fn prepare(ctx: ?*anyopaque, source: *rpc.served_setup.Served) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const owner = try resources.Resources.open(source);
            if (!attachRuntime(source, self.asked, owner.arena.allocator(), self.io)) return error.RuntimeUnavailable;
        }
    };
    var binding: Binding = .{ .asked = asked, .io = io };
    var workbench: Workbench = .{};
    try workbench.openWithCache(io, asked.workspace, asked.build_zig, asked.build_toolchain_cache);
    defer workbench.close();
    var inventory: targets.Inventory = .{};
    defer inventory.close();
    const default_machine = if (asked.elf == null) &machine.catalog.ra8d2 else &machine.catalog.ra8p1;
    var slot: rpc.session_slot.Slot = undefined;
    try slot.init(allocator, io, .{
        .startup = .{ .machine = asked.machine orelse default_machine, .card = asked.sdhi },
        .history = history,
        .second = if (asked.cpu1) |path| .{ .path = path } else null,
        .context = &binding,
        .prepareFn = Binding.prepare,
    });
    defer slot.deinit();
    workbench.bind(&slot.context);
    defer workbench.unbind(&slot.context);
    try inventory.bind(allocator, io, asked.targets, &slot.context);
    if (asked.elf) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(bytes);
        const hooks = slot.context.lifecycle.?;
        try hooks.loadFn(hooks.context, bytes);
        hooks.commitFn(hooks.context);
    }
    const buffers: loop.Buffers = .{ .rx = slot.rx, .tx = slot.tx };
    switch (asked.where) {
        .stdio => try loop.answerStdio(io, &slot.context, buffers),
        .listen => |spec| try listen.serve(io, spec, &slot.context, buffers),
    }
    if (slot.active) |source| try source.flushHistory();
    return 0;
}
