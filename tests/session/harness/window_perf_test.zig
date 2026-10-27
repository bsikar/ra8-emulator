const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("../history/window_rig.zig");

fn timeRun(window: ?usize, count: u64, chunk: u64) !u64 {
    var h = try rig.openCounting(std.testing.allocator, window);
    defer h.deinit();
    const t0 = std.Io.Timestamp.now(std.testing.io, .awake);
    var left = count;
    while (left > 0) {
        const n = @min(left, chunk);
        try rig.runCount(&h, n);
        left -= n;
    }
    return @intCast(@max(0, t0.untilNow(std.testing.io, .awake).nanoseconds));
}

fn report(name: []const u8, n: u64, chunk: u64) !void {
    const off = try timeRun(null, n, chunk);
    const on = try timeRun(64 * 1024 * 1024, n, chunk);
    std.debug.print("[perf] {s} n={d} chunk={d} off={d} ns on={d} ns ratio={d:.3}\n", .{ name, n, chunk, off, on, @as(f64, @floatFromInt(on)) / @as(f64, @floatFromInt(off)) });
}

test "perf" {
    try report("long", 1_000_000, 1_000_000);
    try report("default-budget-chunks", 1_000_000, 4097);
    try report("recorded-chunks", 20_000, 4096);
    try report("steps", 2000, 1);
}

test "sizes" {
    var h = try rig.openCounting(std.testing.allocator, null);
    defer h.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try h.state.files.writeParts(&out.writer, .{ .memory = false });
    std.debug.print("[perf] side image bytes={d}\n", .{out.written().len});
    const t0 = std.Io.Timestamp.now(std.testing.io, .awake);
    for (0..200) |_| {
        out.clearRetainingCapacity();
        try h.state.files.writeParts(&out.writer, .{ .memory = false });
    }
    std.debug.print("[perf] side save ns each={d}\n", .{@divTrunc(t0.untilNow(std.testing.io, .awake).nanoseconds, 200)});
    var rd = try ra8.snapshot.file.Reader.open(out.written());
    while (try rd.next()) |sec| std.debug.print("[perf] section {s} {d}\n", .{ @tagName(sec.kind), sec.payload.len });
}
