//! Covers src/session/history/prefetch.zig: the budget table, the
//! worker clamp, the memory share accounting, hash-verified loading and
//! the discarding of stale epochs.
const std = @import("std");
const ra8 = @import("ra8");
const prefetch = ra8.session.history_prefetch;
const ObjectId = ra8.session.history_object_id.ObjectId;
const mib = prefetch.mib;

test "budget scales workers: 1 GiB allowed, 512 MiB one, 256 MiB and the floor none" {
    const gib = prefetch.Config.forBudget(1024 * mib, prefetch.default_share);
    try std.testing.expectEqual(@as(u64, 640 * mib), gib.capacity);
    try std.testing.expectEqual(@as(u32, 5), gib.workers);
    const half = prefetch.Config.forBudget(512 * mib, prefetch.default_share);
    try std.testing.expectEqual(@as(u64, 320 * mib), half.capacity);
    try std.testing.expectEqual(@as(u32, 1), half.workers);
    try std.testing.expectEqual(@as(u32, 0), prefetch.Config.forBudget(256 * mib, prefetch.default_share).workers);
    try std.testing.expectEqual(@as(u32, 0), prefetch.Config.forBudget(128 * mib, prefetch.default_share).workers);
    try std.testing.expectEqual(@as(u64, 128 * mib), gib.share);
}

test "a disabled budget refuses every request" {
    var p = prefetch.Prefetch.init(std.testing.allocator, prefetch.Config.forBudget(256 * mib, prefetch.default_share));
    defer p.deinit();
    try std.testing.expectError(prefetch.Error.Disabled, p.request(.{ .id = 1, .object = ObjectId.zero }));
}

fn small(workers: u32, shares: u64) prefetch.Config {
    return .{ .workers = workers, .share = 100, .capacity = 100 * shares };
}

test "requests are bounded by the share capacity" {
    var p = prefetch.Prefetch.init(std.testing.allocator, small(8, 2));
    defer p.deinit();
    try p.request(.{ .id = 1, .object = ObjectId.zero });
    try p.request(.{ .id = 2, .object = ObjectId.zero });
    try std.testing.expectError(prefetch.Error.OverBudget, p.request(.{ .id = 3, .object = ObjectId.zero }));
    // Asking again for one already queued is a no-op, not a refusal.
    try p.request(.{ .id = 2, .object = ObjectId.zero });
    try std.testing.expectEqual(@as(usize, 2), p.queued());
}

test "running workers never exceed the clamp" {
    var p = prefetch.Prefetch.init(std.testing.allocator, small(2, 8));
    defer p.deinit();
    for (1..5) |i| try p.request(.{ .id = @intCast(i), .object = ObjectId.zero });
    const a = (try p.claim()).?;
    const b = (try p.claim()).?;
    try std.testing.expect((try p.claim()) == null);
    try std.testing.expectEqual(@as(usize, 2), p.running());
    p.fail(a);
    const c = (try p.claim()).?;
    try std.testing.expectEqual(@as(u32, 3), c.request.id);
    p.fail(b);
    p.fail(c);
    try std.testing.expectEqual(@as(usize, 0), p.running());
}

test "a result in the current epoch is kept and taken once" {
    var p = prefetch.Prefetch.init(std.testing.allocator, small(1, 4));
    defer p.deinit();
    try p.request(.{ .id = 7, .object = ObjectId.zero });
    const job = (try p.claim()).?;
    const bytes = try std.testing.allocator.dupe(u8, "snapshot");
    try std.testing.expectEqual(prefetch.Finished.kept, try p.finish(job, bytes));
    const got = p.take(7).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("snapshot", got);
    try std.testing.expect(p.take(7) == null);
}

test "a result that returns after a new command is discarded" {
    var p = prefetch.Prefetch.init(std.testing.allocator, small(1, 4));
    defer p.deinit();
    try p.request(.{ .id = 7, .object = ObjectId.zero });
    const job = (try p.claim()).?;
    try std.testing.expectEqual(@as(u64, 1), p.bump());
    const bytes = try std.testing.allocator.dupe(u8, "stale");
    try std.testing.expectEqual(prefetch.Finished.stale, try p.finish(job, bytes));
    try std.testing.expect(p.take(7) == null);
    try std.testing.expectEqual(@as(usize, 0), p.running());
}

test "a new command cancels what is still queued" {
    var p = prefetch.Prefetch.init(std.testing.allocator, small(1, 4));
    defer p.deinit();
    try p.request(.{ .id = 1, .object = ObjectId.zero });
    try p.request(.{ .id = 2, .object = ObjectId.zero });
    _ = p.bump();
    try std.testing.expectEqual(@as(usize, 0), p.queued());
    try std.testing.expect((try p.claim()) == null);
}

test "a snapshot larger than the room left is dropped" {
    var p = prefetch.Prefetch.init(std.testing.allocator, small(1, 2));
    defer p.deinit();
    try p.request(.{ .id = 1, .object = ObjectId.zero });
    const job = (try p.claim()).?;
    const big = try std.testing.allocator.alloc(u8, 250);
    try std.testing.expectEqual(prefetch.Finished.over_budget, try p.finish(job, big));
    try std.testing.expect(p.take(1) == null);
}

const Store = struct {
    bytes: []const u8,

    fn source(self: *Store) prefetch.ObjectSource {
        return .{ .context = self, .read = read };
    }

    fn read(ctx: *anyopaque, allocator: std.mem.Allocator, object: ObjectId) prefetch.Error![]u8 {
        _ = object;
        const self: *Store = @ptrCast(@alignCast(ctx));
        return allocator.dupe(u8, self.bytes) catch return prefetch.Error.OutOfMemory;
    }
};

test "load verifies the object hash and refuses forged bytes" {
    var store: Store = .{ .bytes = "real bytes" };
    const good: prefetch.Job = .{ .request = .{ .id = 1, .object = ObjectId.compute("real bytes") }, .epoch = 0 };
    const bytes = try prefetch.load(std.testing.allocator, store.source(), good);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("real bytes", bytes);

    const forged: prefetch.Job = .{ .request = .{ .id = 2, .object = ObjectId.compute("other") }, .epoch = 0 };
    try std.testing.expectError(prefetch.Error.BadHash, prefetch.load(std.testing.allocator, store.source(), forged));
}

test "a ready snapshot is taken by its object, once" {
    var p = prefetch.Prefetch.init(std.testing.allocator, small(1, 4));
    defer p.deinit();
    const object = ObjectId.compute("snapshot");
    try p.request(.{ .id = 9, .object = object });
    const job = (try p.claim()).?;
    const bytes = try std.testing.allocator.dupe(u8, "snapshot");
    try std.testing.expectEqual(prefetch.Finished.kept, try p.finish(job, bytes));
    try std.testing.expect(p.takeObject(ObjectId.compute("other")) == null);
    const got = p.takeObject(object).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("snapshot", got);
    try std.testing.expect(p.takeObject(object) == null);
}

fn firstByte(bytes: []const u8) ObjectId {
    var id = ObjectId.zero;
    id.bytes[0] = bytes[0];
    return id;
}

test "a source that files objects under its own digest is verified with it" {
    var store: Store = .{ .bytes = "real bytes" };
    var source = store.source();
    source.hash = &firstByte;
    const job: prefetch.Job = .{ .request = .{ .id = 1, .object = firstByte("r") }, .epoch = 0 };
    const bytes = try prefetch.load(std.testing.allocator, source, job);
    defer std.testing.allocator.free(bytes);
    const wrong: prefetch.Job = .{ .request = .{ .id = 2, .object = firstByte("x") }, .epoch = 0 };
    try std.testing.expectError(prefetch.Error.BadHash, prefetch.load(std.testing.allocator, source, wrong));
}
