//! Covers src/interfaces/rpc/served_prefetch.zig, prefetch_hook.zig and
//! prefetch_pool.zig through a served session with a disk history: the
//! pool's workers follow the RAM budget, a seek asks for the checkpoints
//! beside its target, the loaded snapshot is the checkpoint object, and a
//! result that returns after a newer command is discarded.
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const pool_mod = ra8.rpc.prefetch_pool;
const transport = ra8.session.transport;
const seek_facts = ra8.session.history_seek_facts;
const prefetch = ra8.session.history_prefetch;
const mib = prefetch.mib;

const image = "tests/fixtures/dfu/dfu_bootloader.elf";

const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 1_000_000;
        return self.now_ns;
    }
    fn wall(self: *FakeWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

/// A source that holds every read until released, so a test can move the
/// epoch while a worker is mid-load.
const Gate = struct {
    inner: prefetch.ObjectSource,
    entered: std.atomic.Value(u32) = .init(0),
    released: std.atomic.Value(bool) = .init(false),

    fn source(self: *Gate) prefetch.ObjectSource {
        return .{ .context = self, .read = &read, .hash = self.inner.hash };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, object: pool_mod.ObjectId) prefetch.Error![]u8 {
        const self: *Gate = @ptrCast(@alignCast(context));
        _ = self.entered.fetchAdd(1, .acq_rel);
        while (!self.released.load(.acquire)) std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
        return self.inner.read(self.inner.context, allocator, object);
    }
};

fn waitFor(pool: *pool_mod.Pool, comptime field: []const u8, want: u64) !void {
    for (0..5000) |_| {
        if (@field(pool.counts(), field) >= want) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake) catch {};
    }
    return error.Timeout;
}

fn rootOf(gpa: std.mem.Allocator, temp: *std.testing.TmpDir) ![:0]u8 {
    return temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
}

fn seekTo(served: *setup.Served, gpa: std.mem.Allocator, index: usize) !void {
    const t = served.owner.transport();
    const bridge = t.history.?;
    const facts = try seek_facts.gather(gpa, try bridge.logBytes.?(bridge.context));
    defer gpa.free(facts.checkpoints);
    const at = facts.checkpoints[index].position;
    const text = try std.fmt.allocPrint(gpa, "{d}:{s}:{d}:{s}", .{ at.r, @tagName(at.phase), at.o, @tagName(at.gap) });
    defer gpa.free(text);
    var wall = FakeWall{};
    _ = try t.command(.{ .seek = .{ .target = text } });
    const pumped = try t.pump(wall.wall(), wall.now_ns + 4_000_000);
    try std.testing.expect(pumped.finished != null);
}

fn openWith(served: *setup.Served, gpa: std.mem.Allocator, root: []const u8, ram_mib: u64) !void {
    try served.open(gpa, std.testing.io, image, null, .{ .root = root, .checkpoint_every = 1, .ram_budget = ram_mib * mib });
}

test "a 1 GiB budget starts prefetch workers and a 256 MiB budget starts none" {
    const gpa = std.testing.allocator;
    var big_dir = std.testing.tmpDir(.{});
    defer big_dir.cleanup();
    const big_root = try rootOf(gpa, &big_dir);
    defer gpa.free(big_root);
    var big: setup.Served = undefined;
    try openWith(&big, gpa, big_root, 1024);
    defer big.deinit();
    try std.testing.expectEqual(@as(usize, 5), big.prefetch.?.pool.workers());
    try std.testing.expect(big.owner.session().prefetch_pool != null);
    try std.testing.expect(big.owner.transport().hook != null);

    var mid_dir = std.testing.tmpDir(.{});
    defer mid_dir.cleanup();
    const mid_root = try rootOf(gpa, &mid_dir);
    defer gpa.free(mid_root);
    var mid: setup.Served = undefined;
    try openWith(&mid, gpa, mid_root, 512);
    defer mid.deinit();
    try std.testing.expectEqual(@as(usize, 1), mid.prefetch.?.pool.workers());

    var small_dir = std.testing.tmpDir(.{});
    defer small_dir.cleanup();
    const small_root = try rootOf(gpa, &small_dir);
    defer gpa.free(small_root);
    var small: setup.Served = undefined;
    try openWith(&small, gpa, small_root, 256);
    defer small.deinit();
    try std.testing.expectEqual(@as(usize, 0), small.prefetch.?.pool.workers());
    try std.testing.expectError(prefetch.Error.Disabled, small.owner.session().prefetch(.{ .id = 1, .object = .zero }));
}

test "a ram-only history opens no prefetch pool" {
    const gpa = std.testing.allocator;
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, .{ .ram_budget = 1024 * mib });
    defer served.deinit();
    try std.testing.expect(served.prefetch == null);
    try std.testing.expect(served.owner.session().prefetch_pool == null);
}

test "a seek loads the neighbouring checkpoints verified against their digest" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try rootOf(gpa, &temp);
    defer gpa.free(root);
    var served: setup.Served = undefined;
    try openWith(&served, gpa, root, 1024);
    defer served.deinit();
    const session = served.owner.session();
    _ = try session.run(.cpu0, .run);
    const pool = served.prefetch.?.pool;

    const facts = try seek_facts.gather(gpa, try served.owner.transport().history.?.logBytes.?(served.owner.transport().history.?.context));
    defer gpa.free(facts.checkpoints);
    try std.testing.expect(facts.checkpoints.len >= 3);

    try seekTo(&served, gpa, 1);
    try waitFor(pool, "kept", 1);
    // The checkpoint behind the base came back verified against the digest
    // the recorder filed it under, and a restore consumes it once.
    const behind = pool_mod.ObjectId{ .bytes = facts.checkpoints[0].object };
    const bytes = pool.take(behind).?;
    defer gpa.free(bytes);
    try std.testing.expect(pool_mod.digest(bytes).eql(behind));
    try std.testing.expect(pool.take(behind) == null);
    try std.testing.expectEqual(@as(u64, 0), pool.counts().failed);
}

test "a result that returns after a newer command is discarded" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try rootOf(gpa, &temp);
    defer gpa.free(root);
    var served: setup.Served = undefined;
    try openWith(&served, gpa, root, 1024);
    defer served.deinit();
    const session = served.owner.session();
    _ = try session.run(.cpu0, .run);
    const pool = served.prefetch.?.pool;

    var gate: Gate = .{ .inner = pool.source };
    pool.source = gate.source();
    defer gate.released.store(true, .release);

    try seekTo(&served, gpa, 1);
    for (0..5000) |_| {
        if (gate.entered.load(.acquire) > 0) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake) catch {};
    }
    try std.testing.expect(gate.entered.load(.acquire) > 0);

    // Any later command moves the epoch while the load is still held.
    _ = try served.owner.transport().command(.pause);
    gate.released.store(true, .release);
    try waitFor(pool, "stale", 1);
    try std.testing.expectEqual(@as(u64, 0), pool.counts().kept);
}
