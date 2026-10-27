//! RPC handlers for navigation and playback (Slice 22.4).
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const session_mod = @import("ra8_session");

const OutcomeAck = rpc.Outcome(proto.Ack);
const OutcomeResult = rpc.Outcome(proto.NavQueryResult);

pub fn play(context: *handlers.Context, args: proto.PlayArgs) OutcomeAck {
    const plane = context.transport orelse return refuse();
    const dir: session_mod.transport.Direction = if (args.dir == .back) .back else .fwd;
    const factor: ?f64 = if (args.speed_milli == 0) null else @as(f64, @floatFromInt(args.speed_milli)) / 1000.0;
    _ = plane.command(.{ .play = .{ .dir = dir, .speed = factor } }) catch |err| switch (err) {
        error.InvalidSpeed, error.InvalidArgs => return .{ .err = .bad_args },
        else => return refuse(),
    };
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn navQuery(context: *handlers.Context, args: proto.NavQueryArgs) OutcomeResult {
    const nav = context.session.nav_index orelse {
        return .{ .ok = .{ .found = 0 } };
    };
    switch (args.kind) {
        .frame => return queryFrame(nav, args.index),
        .iteration => return queryIteration(nav, args.index),
        .marker => return queryMarker(nav, args.name, args.index),
        .rtos => return queryRtos(nav),
        .isr => return .{ .ok = .{ .found = if (nav.isrTransitionCount() > 0) 1 else 0, .count = nav.isrTransitionCount() } },
    }
}

/// The frame pipeline's byte accounting, with the rewind's decode count.
pub fn frameStatus(context: *handlers.Context, _: proto.CoreOnly) rpc.Outcome(proto.FrameStatusResult) {
    const hook = context.nav.status orelse return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    const read = hook.readFn(hook.context);
    const decoded: u64 = if (context.session.smooth_rewind) |rewind| rewind.decoded_segments else 0;
    return .{ .ok = .{
        .ram_bytes = read.ram_bytes,
        .disk_bytes = read.disk_bytes,
        .queue_bytes = read.queue_bytes,
        .frames = read.frames,
        .decoded_segments = decoded,
    } };
}

fn queryFrame(nav: *const session_mod.history_nav_index.NavIndex, index: u64) OutcomeResult {
    const count = nav.frameCount();
    if (nav.getFrame(index)) |pos| {
        return .{ .ok = .{
            .found = 1,
            .branch = pos.branch,
            .r = pos.r,
            .phase = @backingInt(pos.phase),
            .o = pos.o,
            .gap = @backingInt(pos.gap),
            .count = count,
        } };
    }
    return .{ .ok = .{ .found = 0, .count = count } };
}

fn queryIteration(nav: *const session_mod.history_nav_index.NavIndex, n: u64) OutcomeResult {
    const count = nav.iterationCount();
    if (nav.getIteration(n)) |pos| {
        const slots = nav.getIterationSlots(n) orelse 0;
        return .{ .ok = .{
            .found = 1,
            .branch = pos.branch,
            .r = pos.r,
            .phase = @backingInt(pos.phase),
            .o = pos.o,
            .gap = @backingInt(pos.gap),
            .count = count,
            .slots = slots,
        } };
    }
    return .{ .ok = .{ .found = 0, .count = count } };
}

fn queryMarker(nav: *const session_mod.history_nav_index.NavIndex, name: []const u8, nth: u64) OutcomeResult {
    const arrival_nth: u64 = if (nth == 0) 1 else nth;
    if (nav.getMarkerArrival(name, arrival_nth)) |pos| {
        return .{ .ok = .{
            .found = 1,
            .branch = pos.branch,
            .r = pos.r,
            .phase = @backingInt(pos.phase),
            .o = pos.o,
            .gap = @backingInt(pos.gap),
        } };
    }
    if (nav.getBookmark(name)) |pos| {
        return .{ .ok = .{
            .found = 1,
            .branch = pos.branch,
            .r = pos.r,
            .phase = @backingInt(pos.phase),
            .o = pos.o,
            .gap = @backingInt(pos.gap),
        } };
    }
    return .{ .ok = .{ .found = 0 } };
}

fn queryRtos(nav: *const session_mod.history_nav_index.NavIndex) OutcomeResult {
    const count = nav.rtosSwitchCount();
    return .{ .ok = .{ .found = if (count > 0) 1 else 0, .count = count } };
}

fn refuse() OutcomeAck {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
