//! Host threads behind the C6 DNS bridge's Worker (RA8EMU-1020).
const std = @import("std");
const ra8 = @import("ra8");
const host_worker = ra8.host.worker;
const Worker = ra8.periph.esp_hosted.worker.Worker;

fn bump(arg: *anyopaque) void {
    const count: *std.atomic.Value(u32) = @ptrCast(@alignCast(arg));
    _ = count.fetchAdd(1, .acq_rel);
}

test "a spawned job has run once join returns" {
    var count: std.atomic.Value(u32) = .init(0);
    host_worker.join(try host_worker.spawn(bump, &count));
    try std.testing.expectEqual(@as(u32, 1), count.load(.acquire));
}

test "the C6 Worker over host threads runs and joins jobs" {
    const background: Worker = .of(host_worker);
    var count: std.atomic.Value(u32) = .init(0);
    const first = try background.spawn(bump, &count);
    const second = try background.spawn(bump, &count);
    background.join(first);
    background.join(second);
    try std.testing.expectEqual(@as(u32, 2), count.load(.acquire));
}
