//! Reacquire both roots before settling a root-anchored native operation.
const std = @import("std");
const h = @import("../root.zig");
const intent = @import("intent.zig");
const Context = @import("context.zig").Context;
const Base = h.base.Base;

pub fn root(base: *const Base, id: []const u8) anyerror!void {
    var buffer: h.name.Buffer = undefined;
    const anchor = try intent.leaf(&buffer, id);
    const saved = saved: {
        var gate = try base.gate(.exclusive);
        defer gate.release();
        const lease = (try h.lock.take(base.io, base.dir, id)) orelse return error.Locked;
        defer lease.close(base.io);
        break :saved try intent.read(base.allocator, base.io, base.dir, anchor, true);
    };
    defer saved.deinit();
    const record = saved.value;
    var other: ?Base = null;
    if (!std.mem.eql(u8, base.path, record.to_path)) {
        if (base.role != .cache or !std.mem.startsWith(u8, record.purpose, h.layout.moves.keep)) return error.BadReceipt;
        other = try Base.existingConfigured(base.allocator, base.io, record.to_path, .kept, .{ .native_provider = base.native_provider, .recover = false });
    }
    defer if (other) |*target| target.close();
    const target: *const Base = if (other) |*value| value else base;
    var gates = try h.gates.Pair.acquire(base, target);
    defer gates.release();
    const lease = (try h.lock.take(base.io, base.dir, id)) orelse return error.Locked;
    var source_open = true;
    defer if (source_open) lease.close(base.io);
    const arrived = if (other != null) h.lock.create(base.io, target.dir, id) catch |err| switch (err) {
        error.PathAlreadyExists => (try h.lock.take(base.io, target.dir, id)) orelse return error.Locked,
        else => return err,
    } else null;
    defer if (arrived) |held| held.close(base.io);
    var authorities: [4]std.Io.File = undefined;
    var count: usize = 0;
    authorities[count] = gates.first.file;
    count += 1;
    if (gates.second) |gate| {
        authorities[count] = gate.file;
        count += 1;
    }
    authorities[count] = lease;
    count += 1;
    if (arrived) |held| {
        authorities[count] = held;
        count += 1;
    }
    const context: Context = .{ .source = base, .target = target, .authorities = authorities[0..count] };
    const current = try intent.read(base.allocator, base.io, base.dir, anchor, true);
    defer current.deinit();
    if (!current.value.anchor.same(record.anchor)) return error.IdentityConflict;
    try @import("bridge.zig").settle(context, base.native_provider, current.value);
    if (other != null) {
        source_open = false;
        try h.lock.retire(base.io, base.dir, id, lease);
    }
}
