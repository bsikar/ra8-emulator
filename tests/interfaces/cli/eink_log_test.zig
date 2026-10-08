//! Tests for src/interfaces/cli/eink_log.zig.
const std = @import("std");
const ra8 = @import("ra8");
const eink_log = ra8.core.eink_log;
const eink = ra8.periph.eink;
const proto = ra8.periph.eink_wire;

fn word(panel: *eink.Panel, value: u16) void {
    _ = panel.exchange(@intCast(value >> 8));
    _ = panel.exchange(@intCast(value & 0xff));
}

fn data(panel: *eink.Panel, value: u16) void {
    word(panel, proto.preamble.write);
    word(panel, value);
}

fn refresh(panel: *eink.Panel, x: u16, y: u16, width: u16, height: u16, mode: u16) void {
    word(panel, proto.preamble.command);
    word(panel, @backingInt(proto.Command.display_area));
    data(panel, x);
    data(panel, y);
    data(panel, width);
    data(panel, height);
    data(panel, mode);
}

test "scripted full and partial refreshes produce JSONL and totals by waveform" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var recorder = eink_log.Run.init(std.testing.allocator, &board);
    defer recorder.deinit();
    recorder.arm();

    const panel = &board.panel;
    const geometry = panel.planes.geometry;
    refresh(panel, 0, 0, geometry.width, geometry.height, 2);
    refresh(panel, 4, 7, 50, 30, 3);
    refresh(panel, 1, 2, 4, 5, 2);

    try std.testing.expectEqual(@as(usize, 3), recorder.entries.items.len);
    try std.testing.expect(recorder.entries.items[0].full);
    try std.testing.expect(!recorder.entries.items[1].full);
    try std.testing.expectEqual(@as(u16, 3), recorder.entries.items[1].waveform);

    var totals = std.ArrayList(u8).init(std.testing.allocator);
    defer totals.deinit();
    var j = ra8.board.report.json.over(totals.writer());
    try recorder.reportJson(&j);
    try std.testing.expect(std.mem.indexOf(u8, totals.items, "\"waveform\":2,\"count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, totals.items, "\"waveform\":3,\"count\":1") != null);

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const log_path = try std.fs.path.join(std.testing.allocator, &.{ path, "refresh.jsonl" });
    defer std.testing.allocator.free(log_path);
    try recorder.write(std.testing.io, log_path);
    const file = try std.fs.cwd().openFile(log_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(contents);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"virtual_time_ns\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"waveform\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "\"full\":false") != null);
}
