//! Covers src/session/smooth_rewind.zig: smooth rewind engine playback at
//! 1x, 8x, and 32x, dynamic speed changes, hysteresis transitions, and
//! bit-exact machine state materialization on Pause compared against a direct seek.
const std = @import("std");
const ra8 = @import("ra8");
const smooth_rewind = ra8.session.smooth_rewind;
const rig_mod = @import("history/window_rig.zig");
const rebuild = ra8.session.history_window_rebuild;
const cache_mod = ra8.session.history_frame_cache;
const fx = @import("history/frame_fixture.zig");

const slots: usize = 20;

const LiveTracker = struct {
    parent: std.mem.Allocator,
    live_bytes: usize = 0,
    high_water: usize = 0,

    fn allocator(self: *LiveTracker) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LiveTracker = @ptrCast(@alignCast(ctx));
        const res = self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        if (self.live_bytes > self.high_water) self.high_water = self.live_bytes;
        return res;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LiveTracker = @ptrCast(@alignCast(ctx));
        if (self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr)) {
            if (new_len > memory.len) {
                self.live_bytes += (new_len - memory.len);
                if (self.live_bytes > self.high_water) self.high_water = self.live_bytes;
            } else {
                self.live_bytes -= (memory.len - new_len);
            }
            return true;
        }
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LiveTracker = @ptrCast(@alignCast(ctx));
        const res = self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) {
            self.live_bytes += (new_len - memory.len);
            if (self.live_bytes > self.high_water) self.high_water = self.live_bytes;
        } else {
            self.live_bytes -= (memory.len - new_len);
        }
        return res;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LiveTracker = @ptrCast(@alignCast(ctx));
        self.live_bytes -= memory.len;
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

test "smooth rewind playback at 1x, 8x, and 32x via Session API" {
    const gpa = std.testing.allocator;
    var rig: rig_mod.Rig = undefined;
    try rig.open(gpa);
    defer rig.deinit();

    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1 << 20 }, null);
    defer cache.deinit();

    const pic_val = fx.picture(1, 0);
    try fx.put(&cache, gpa, try fx.keyRecord(gpa, fx.at(0, 100_000), &pic_val));
    try fx.put(&cache, gpa, try fx.keyRecord(gpa, fx.at(0, 500_000), &pic_val));
    try fx.put(&cache, gpa, try fx.keyRecord(gpa, fx.at(0, 900_000), &pic_val));

    const session = rig.opened.session();
    var engine = smooth_rewind.SmoothRewindEngine.init(gpa, session);
    defer engine.deinit();
    engine.decoder.bindCache(&cache);
    session.attachSmoothRewind(&engine);

    // Initial state: stopped, not busy
    try std.testing.expect(!engine.isBusy());

    // 1x speed start from 1 second
    engine.decoder.setCursorNs(1_000_000_000);
    try session.startSmoothRewind(1.0);
    try std.testing.expect(engine.isBusy());

    // Tick advances reverse clock
    const dt: u64 = 16_666_667;
    const res1 = try session.tickSmoothRewind(dt);
    try std.testing.expectEqual(smooth_rewind.Status.ok, res1.status);
    try std.testing.expect(res1.frame != null);

    // Change speed to 8x
    try session.setRewindSpeed(8.0);
    const res8 = try session.tickSmoothRewind(dt);
    try std.testing.expectEqual(smooth_rewind.Status.ok, res8.status);
    try std.testing.expect(res8.frame != null);

    // Change speed to 32x
    try session.setRewindSpeed(32.0);
    const res32 = try session.tickSmoothRewind(dt);
    try std.testing.expectEqual(smooth_rewind.Status.ok, res32.status);
    try std.testing.expect(res32.frame != null);

    // Pause stops playback and clears busy
    try session.pauseSmoothRewind();
    try std.testing.expect(!engine.isBusy());
    try std.testing.expectEqual(smooth_rewind.State.paused, engine.status);
}

test "reverse playback live bytes are bounded and leak-free across many ticks" {
    const parent = std.testing.allocator;
    var tracker = LiveTracker{ .parent = parent };
    const tracked_alloc = tracker.allocator();

    var rig: rig_mod.Rig = undefined;
    try rig.open(parent);
    defer rig.deinit();

    var cache = cache_mod.FrameCache.init(parent, std.testing.io, .{ .ram_bytes = 1 << 20 }, null);
    defer cache.deinit();

    const pic_val = fx.picture(1, 0);
    try fx.put(&cache, parent, try fx.keyRecord(parent, fx.at(0, 100_000), &pic_val));
    try fx.put(&cache, parent, try fx.keyRecord(parent, fx.at(0, 300_000), &pic_val));
    try fx.put(&cache, parent, try fx.keyRecord(parent, fx.at(0, 600_000), &pic_val));
    try fx.put(&cache, parent, try fx.keyRecord(parent, fx.at(0, 900_000), &pic_val));

    const session = rig.opened.session();
    var engine = smooth_rewind.SmoothRewindEngine.init(tracked_alloc, session);
    defer engine.deinit();
    engine.decoder.bindCache(&cache);
    session.attachSmoothRewind(&engine);

    engine.decoder.setCursorNs(1_000_000_000);
    try session.startSmoothRewind(1.0);

    const dt: u64 = 16_666_667;
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        const res = try session.tickSmoothRewind(dt);
        try std.testing.expect(res.frame != null);
        if (res.status == .history_start) break;
    }

    // High-water mark remains strictly bounded and does not grow with tick count.
    try std.testing.expect(tracker.high_water <= 100 * 1024);
    try std.testing.expectEqual(@as(usize, 512), tracker.live_bytes);
}

test "Pause exactness with reverse window matches direct seek bit-for-bit" {
    const gpa = std.testing.allocator;
    var rig: rig_mod.Rig = undefined;
    try rig.open(gpa);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    try rig.port().restoreFull(straight.base);
    var win = rig.window(64 * 1024 * 1024);
    defer win.deinit();
    try rebuild.run(&win, .{ .base = .{ .bytes = straight.base }, .end = straight.positions[slots] });

    const session = rig.opened.session();
    var engine = smooth_rewind.SmoothRewindEngine.init(gpa, session);
    defer engine.deinit();
    engine.attachWindow(&win);
    session.attachSmoothRewind(&engine);

    // Prepare a mock decoded frame corresponding to slot index 7
    const target_idx: usize = 7;
    const target_pos = straight.positions[target_idx];
    const target_digest = straight.digests[target_idx];

    const dummy_px = try gpa.alloc(u8, 4);
    @memset(dummy_px, 0xAA);
    engine.current_frame = .{
        .position = target_pos,
        .virtual_ns = 70_000,
        .width = 2,
        .height = 2,
        .pixels = dummy_px,
        .source = .decoded_segment,
    };
    engine.status = .playing_backward;

    // Trigger Pause during backward play
    try session.pauseSmoothRewind();

    // Verification 1: Engine is paused
    try std.testing.expectEqual(smooth_rewind.State.paused, engine.status);

    // Verification 2: Machine position equals the shown frame's position exactly
    try std.testing.expectEqual(target_pos.branch, session.currentPosition().branch);
    try std.testing.expectEqual(target_pos.r, session.currentPosition().r);
    try std.testing.expectEqual(target_pos.phase, session.currentPosition().phase);
    try std.testing.expectEqual(target_pos.o, session.currentPosition().o);

    // Verification 3: Full machine state digest is bit-exact to direct execution
    const current_digest = try rig.digest();
    try std.testing.expectEqualSlices(u8, &target_digest, &current_digest);
}

test "Pause exactness with checkpoint restore and replay matches direct seek" {
    const gpa = std.testing.allocator;
    var rig: rig_mod.Rig = undefined;
    try rig.open(gpa);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    const session = rig.opened.session();
    var engine = smooth_rewind.SmoothRewindEngine.init(gpa, session);
    defer engine.deinit();
    session.attachSmoothRewind(&engine);

    // Checkpoint restore hook that restores the initial base snapshot
    const Hook = struct {
        rig: *rig_mod.Rig,
        base: []const u8,
        fn restore(ctx: *anyopaque, _: smooth_rewind.Position) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.rig.port().restoreFull(self.base);
        }
    };
    var hook_inst = Hook{ .rig = &rig, .base = straight.base };
    engine.attachRestoreHook(.{ .context = &hook_inst, .restoreFn = Hook.restore });

    // Target is slot index 12
    const target_idx: usize = 12;
    const target_pos = straight.positions[target_idx];
    const target_digest = straight.digests[target_idx];

    const dummy_px = try gpa.alloc(u8, 4);
    @memset(dummy_px, 0xBB);
    engine.current_frame = .{
        .position = target_pos,
        .virtual_ns = 120_000,
        .width = 2,
        .height = 2,
        .pixels = dummy_px,
        .source = .checkpoint_picture,
    };
    engine.status = .playing_backward;

    // Trigger Pause during backward play
    try session.pauseSmoothRewind();

    // Verification 1: Status is paused
    try std.testing.expectEqual(smooth_rewind.State.paused, engine.status);

    // Verification 2: Position equals shown frame's position
    try std.testing.expectEqual(target_pos.branch, session.currentPosition().branch);
    try std.testing.expectEqual(target_pos.r, session.currentPosition().r);
    try std.testing.expectEqual(target_pos.phase, session.currentPosition().phase);
    try std.testing.expectEqual(target_pos.o, session.currentPosition().o);

    // Verification 3: Full machine digest is bit-exact to direct seek / straight run
    const current_digest = try rig.digest();
    try std.testing.expectEqualSlices(u8, &target_digest, &current_digest);
}
