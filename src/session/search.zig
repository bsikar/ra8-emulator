//! Session API entry points for reverse-watch queries and background prefetching.
const std = @import("std");
const api = @import("api.zig");
const reverse_watch = @import("history/reverse_watch.zig");
const prefetch_mod = @import("history/prefetch.zig");
const position_mod = @import("history/position.zig");
const memory_observer = @import("ra8_chip").core.cpu.memory.observer;
const trail = @import("history/trail.zig");

const Session = api.Session;

pub const ReplayObserver = struct {
    sink: *reverse_watch.Sink,
    session: *api.Session,

    fn onBytes(ctx: *anyopaque, write: memory_observer.Write) void {
        const self: *ReplayObserver = @ptrCast(@alignCast(ctx));
        const start: u64 = @as(u64, write.base) + write.offset;
        const len: u32 = @intCast(write.pre.len);
        const addr: u32 = @truncate(start);
        if (!self.sink.range.overlaps(addr, len)) return;
        if (self.session.hasArmedWriteWatch() and self.session.matchingWatch(addr, len) == null) return;
        const grid = self.session.grid orelse return;
        const cpu0 = self.session.live.core.cpu;
        const cpu1 = if (self.session.live.other) |o| o.core.cpu else null;
        const phase: position_mod.Phase = grid.at.phase;
        const o: u32 = switch (phase) {
            .cpu0 => if (cpu0.slots >= grid.base[0]) @intCast(cpu0.slots - grid.base[0] + 1) else 1,
            .cpu1 => if (cpu1 != null and cpu1.?.slots >= grid.base[1]) @intCast(cpu1.?.slots - grid.base[1] + 1) else 1,
            .board => 0,
        };
        const src: trail.Source = switch (write.initiator) {
            .cpu0 => .{ .core = .{ .core = .cpu0, .slots = o } },
            .cpu1 => .{ .core = .{ .core = .cpu1, .slots = o } },
            .none => .untimed,
            else => .{ .board = write.initiator },
        };
        const changed = if (write.new.len == write.pre.len and write.new.len > 0)
            !std.mem.eql(u8, write.pre, write.new)
        else
            true;
        self.sink.report(.{
            .position = .{ .branch = grid.at.branch, .r = grid.at.r, .phase = phase, .o = o, .gap = .retired },
            .address = addr,
            .len = len,
            .initiator = write.initiator,
            .source = src,
            .changed = changed,
        });
    }

    fn onBarrier(_: *anyopaque, _: memory_observer.Barrier) void {}

    pub fn observer(self: *ReplayObserver) memory_observer.Observer {
        return .{ .ctx = self, .vtable = &.{ .bytes = onBytes, .barrier = onBarrier } };
    }
};

pub fn attachPrefetch(self: *Session, pool: *prefetch_mod.Prefetch) void {
    self.prefetch_pool = pool;
}

pub fn prefetch(self: *Session, req: prefetch_mod.Request) prefetch_mod.Error!void {
    const pool = self.prefetch_pool orelse return prefetch_mod.Error.Disabled;
    try pool.request(req);
}

pub fn prefetchCancel(self: *Session) void {
    if (self.prefetch_pool) |pool| {
        _ = pool.bump();
    }
}

fn sessionComparePositions(context: *anyopaque, a: position_mod.Position, b: position_mod.Position) anyerror!std.math.Order {
    const self: *Session = @ptrCast(@alignCast(context));
    return self.comparePositions(a, b);
}

pub fn reverseWatch(
    self: *Session,
    allocator: std.mem.Allocator,
    port: reverse_watch.Port,
    query: reverse_watch.Query,
    checkpoints: []const reverse_watch.Checkpoint,
) reverse_watch.Error!reverse_watch.Result {
    var p = port;
    if (p.compare == null) {
        p.compare = sessionComparePositions;
        p.compare_context = self;
    }
    return reverse_watch.search(allocator, p, query, checkpoints);
}
