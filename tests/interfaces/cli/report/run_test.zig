//! Covers src/interfaces/cli/report/run.zig: the reduced report a
//! `--cpu zig` run prints after the core stops.
const std = @import("std");
const ra8 = @import("ra8");

const report_run = ra8.board.report_run;

/// Run `zigCore` on a fresh board into a scratch file and return what it wrote.
fn zigReport(buf: []u8) ![]const u8 {
    // attach() wires the blocks to their power domains, which the report reads.
    var core = try ra8.core.engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&core);
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const file = try dir.dir.createFile("report.txt", .{ .read = true });
    defer file.close();
    try report_run.zigCore(file.writer(), &board, 42);
    try file.seekTo(0);
    const len = try file.readAll(buf);
    return buf[0..len];
}

test "a zig run reports the bus and the blocks and says what it leaves out" {
    var buf: [4096]u8 = undefined;
    const text = try zigReport(&buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "peripheral accesses: 0 read, 0 written"));
    try std.testing.expect(std.mem.indexOf(u8, text, "zig core: timebase, pend/idle seams and stepped-instruction counts are Unicorn-only, not reported\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "GPIO LEDs: none driven\n") != null);
}

test "a quiet board prints no console line" {
    var buf: [4096]u8 = undefined;
    const text = try zigReport(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "SCI console:") == null);
}
