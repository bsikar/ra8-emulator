//! Tests for navigation and reverse play RPC handlers (Slice 22.4).
const std = @import("std");
const ra8 = @import("ra8");

const proto = ra8.rpc.session.rpc;
const nav_handlers = ra8.rpc.session.nav_handlers;
const nav_index = ra8.session.history_nav_index;
const Rig = @import("advance_rig.zig").Rig;

test "play returns refused when no transport plane is attached" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();

    const result = nav_handlers.play(&rig.context, .{ .dir = .back, .speed_milli = 1000 });
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .err => {},
    }
}

test "play accepts forward and backward playback requests" {
    const allocator = std.testing.allocator;
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    var plane = ra8.session.transport.Transport{ .session = &rig.session };
    rig.context.transport = &plane;

    var rewind_engine = ra8.session.smooth_rewind.SmoothRewindEngine.init(allocator, &rig.session);
    defer rewind_engine.deinit();
    ra8.session.smooth_rewind.attachSmoothRewind(&rig.session, &rewind_engine);

    const back_ack = nav_handlers.play(&rig.context, .{ .dir = .back, .speed_milli = 1000 });
    switch (back_ack) {
        .ok => |ack| try std.testing.expectEqual(@as(u32, 1), ack.accepted),
        .err => return error.TestUnexpectedResult,
    }

    const fwd_ack = nav_handlers.play(&rig.context, .{ .dir = .fwd, .speed_milli = 2000 });
    switch (fwd_ack) {
        .ok => |ack| try std.testing.expectEqual(@as(u32, 1), ack.accepted),
        .err => return error.TestUnexpectedResult,
    }

    const default_speed_ack = nav_handlers.play(&rig.context, .{ .dir = .fwd, .speed_milli = 0 });
    switch (default_speed_ack) {
        .ok => |ack| try std.testing.expectEqual(@as(u32, 1), ack.accepted),
        .err => return error.TestUnexpectedResult,
    }
}

test "navQuery returns found = 0 when nav_index is not attached" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();

    const res = nav_handlers.navQuery(&rig.context, .{
        .kind = .frame,
        .index = 0,
        .name = "",
    });
    switch (res) {
        .ok => |out| try std.testing.expectEqual(@as(u32, 0), out.found),
        .err => return error.TestUnexpectedResult,
    }
}

test "navQuery resolves frames, iterations, markers and RTOS switches" {
    const allocator = std.testing.allocator;
    var index = nav_index.NavIndex.init(allocator);
    defer index.deinit();

    const p0: nav_index.Position = .{ .branch = 0, .r = 100, .phase = .cpu0, .o = 0, .gap = .retired };
    const p1: nav_index.Position = .{ .branch = 0, .r = 200, .phase = .cpu0, .o = 0, .gap = .retired };
    const p2: nav_index.Position = .{ .branch = 0, .r = 300, .phase = .cpu0, .o = 0, .gap = .retired };

    _ = try index.addFrame(p0, 1000);
    _ = try index.addFrame(p1, 2000);

    index.advanceSlots(1);
    _ = try index.addIteration(p0);
    index.advanceSlots(2);
    _ = try index.addIteration(p1);

    _ = try index.addMarkerArrival("mark_start", null, p0);
    try index.setBookmark("bm_mid", p1);

    try index.addRtosSwitch(1, 2, p2, 0);

    var rig = Rig{};
    try rig.open();
    defer rig.close();
    rig.session.nav_index = &index;

    // Frame query
    const f0 = nav_handlers.navQuery(&rig.context, .{ .kind = .frame, .index = 0, .name = "" });
    try std.testing.expectEqual(@as(u32, 1), f0.ok.found);
    try std.testing.expectEqual(@as(u64, 100), f0.ok.r);
    try std.testing.expectEqual(@as(u64, 2), f0.ok.count);

    const f_missing = nav_handlers.navQuery(&rig.context, .{ .kind = .frame, .index = 9, .name = "" });
    try std.testing.expectEqual(@as(u32, 0), f_missing.ok.found);
    try std.testing.expectEqual(@as(u64, 2), f_missing.ok.count);

    // Iteration query
    const it2 = nav_handlers.navQuery(&rig.context, .{ .kind = .iteration, .index = 2, .name = "" });
    try std.testing.expectEqual(@as(u32, 1), it2.ok.found);
    try std.testing.expectEqual(@as(u64, 200), it2.ok.r);
    try std.testing.expectEqual(@as(u64, 3), it2.ok.slots); // 1 + 2

    // Marker queries
    const m0 = nav_handlers.navQuery(&rig.context, .{ .kind = .marker, .index = 0, .name = "mark_start" });
    try std.testing.expectEqual(@as(u32, 1), m0.ok.found);
    try std.testing.expectEqual(@as(u64, 100), m0.ok.r);

    const bm = nav_handlers.navQuery(&rig.context, .{ .kind = .marker, .index = 0, .name = "bm_mid" });
    try std.testing.expectEqual(@as(u32, 1), bm.ok.found);
    try std.testing.expectEqual(@as(u64, 200), bm.ok.r);

    const m_unknown = nav_handlers.navQuery(&rig.context, .{ .kind = .marker, .index = 0, .name = "none" });
    try std.testing.expectEqual(@as(u32, 0), m_unknown.ok.found);

    // RTOS query
    const rtos = nav_handlers.navQuery(&rig.context, .{ .kind = .rtos, .index = 0, .name = "" });
    try std.testing.expectEqual(@as(u32, 1), rtos.ok.found);
    try std.testing.expectEqual(@as(u64, 1), rtos.ok.count);
}
