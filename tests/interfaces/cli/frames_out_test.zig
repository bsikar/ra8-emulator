//! Tests for numbered P6 output in src/interfaces/cli/frames_out.zig.
const std = @import("std");
const ra8 = @import("ra8");
const frames_out = ra8.board.report.frames_out;
const engine = ra8.core.engine;
const glcdc = ra8.periph.glcdc;
const tcon = ra8.periph.glcdc_tcon;
const glcdc_sys = ra8.periph.glcdc_sys;
const pdctr = ra8.periph.pdctr;
const prcr = ra8.periph.prcr;

test "a small panel writes exact P6 bytes and skips an identical scan" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);

    var sequence = try frames_out.Sequence.init(std.testing.allocator, path, 1);
    defer sequence.deinit();
    const pixels = [_]u32{ 0xFF11_2233, 0x0044_5566 };
    try sequence.record(2, 1, &pixels, 0);
    try sequence.record(2, 1, &pixels, 16_666_667);
    try std.testing.expectEqual(@as(usize, 2), sequence.scanned);
    try std.testing.expectEqual(@as(usize, 1), sequence.written);

    var file = try sequence.directory.openFile("frame_00000.ppm", .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(std.testing.allocator, 128);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "P6\n2 1\n255\n\x11\x22\x33\x44\x55\x66", bytes);
    try std.testing.expectError(error.FileNotFound, sequence.directory.openFile("frame_00001.ppm", .{}));
}

test "every Nth scan gets a sequential filename" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);

    var sequence = try frames_out.Sequence.init(std.testing.allocator, path, 2);
    defer sequence.deinit();
    const first = [_]u32{0xFF00_0001};
    const second = [_]u32{0xFF00_0002};
    const third = [_]u32{0xFF00_0003};
    try sequence.record(1, 1, &first, 0);
    try sequence.record(1, 1, &second, 40);
    try sequence.record(1, 1, &third, 80);
    try std.testing.expectEqual(@as(usize, 2), sequence.written);
    try expectIndex(sequence, "frame_00000.ppm 0\nframe_00001.ppm 80\n");
    var file = try sequence.directory.openFile("frame_00001.ppm", .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(std.testing.allocator, 64);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "P6\n1 1\n255\n\x00\x00\x03", bytes);
}

test "capture records the panel pixels from a completed GLCDC scan" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&core);

    board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
    board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 2);
    board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 1);
    board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF11_2233);
    board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);

    var sequence = try frames_out.Sequence.init(std.testing.allocator, path, 1);
    defer sequence.deinit();
    var capture = (try frames_out.FrameCapture.init(std.testing.allocator, &board)).?;
    defer capture.deinit(&board);
    try std.testing.expect(board.display.scanOut() != null);
    try capture.finish(&board, &sequence);

    try std.testing.expectEqual(@as(u32, 1), board.display.system.frames);
    try std.testing.expectEqual(@as(usize, 1), sequence.written);
    var file = try sequence.directory.openFile("frame_00000.ppm", .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(std.testing.allocator, 64);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "P6\n2 1\n255\n\x11\x22\x33\x11\x22\x33", bytes);
    try expectIndex(sequence, "frame_00000.ppm 0\n");
}

/// frames.txt names each written frame with the emulated time it was scanned.
fn expectIndex(sequence: frames_out.Sequence, expected: []const u8) !void {
    const bytes = try sequence.directory.readFileAlloc(std.testing.allocator, "frames.txt", 256);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

test "an armed run keeps one frame per period with its emulated time" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&core);

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);
    const gif_path = try std.fs.path.join(std.testing.allocator, &.{ root, "movie.gif" });
    defer std.testing.allocator.free(gif_path);

    const armed = (try frames_out.Armed.armOutputs(std.testing.allocator, &board, path, gif_path, 1)).?;
    defer armed.deinit();
    const period = ra8.periph.glcdc_out.vsync.default_period_ns;
    board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
    board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 2);
    board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 1);
    board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF11_2233);
    board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);

    board.display.output.vsync.?.tick(period);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF44_5566);
    board.display.output.vsync.?.tick(2 * period);
    try std.testing.expect(frames_out.Armed.of(&board) == armed);

    var report = try frames_out.Run.init(std.testing.allocator, &board, path, 1);
    try report.finish(&board);
    try std.testing.expectEqual(@as(usize, 2), armed.sequence.written);
    try std.testing.expectEqual(@as(usize, 2), armed.sequence.gif_writer.?.wrote);
    try expectIndex(armed.sequence, "frame_00000.ppm 16666667\nframe_00001.ppm 33333334\n");
    var file = try armed.sequence.directory.openFile("frame_00001.ppm", .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(std.testing.allocator, 64);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "P6\n2 1\n255\n\x44\x55\x66\x44\x55\x66", bytes);
}

test "an attached e-ink refresh records its grey glass plane once per refresh" {
    const proto = ra8.periph.eink_wire;
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.asks.attached_eink = &board.panel;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);
    const armed = (try frames_out.Armed.arm(std.testing.allocator, &board, path, 1)).?;
    defer armed.deinit();

    eInkRefresh(&board.panel, proto, 0x2211);
    eInkRefresh(&board.panel, proto, 0x4433);
    try armed.finish();

    try std.testing.expectEqual(@as(usize, 2), armed.sequence.written);
    try expectIndex(armed.sequence, "frame_00000.ppm 0\nframe_00001.ppm 0\n");
    for ([_]struct { name: []const u8, rgb: [6]u8 }{
        .{ .name = "frame_00000.ppm", .rgb = .{ 0x11, 0x11, 0x11, 0x22, 0x22, 0x22 } },
        .{ .name = "frame_00001.ppm", .rgb = .{ 0x33, 0x33, 0x33, 0x44, 0x44, 0x44 } },
    }) |frame| {
        var file = try armed.sequence.directory.openFile(frame.name, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(std.testing.allocator, 128 * 128 * 3 + 32);
        defer std.testing.allocator.free(bytes);
        const header = "P6\n128 128\n255\n";
        try std.testing.expect(std.mem.startsWith(u8, bytes, header));
        try std.testing.expectEqualSlices(u8, &frame.rgb, bytes[header.len .. header.len + 6]);
        try std.testing.expectEqual(@as(u8, 0), bytes[header.len + 6]);
    }
}

fn eInkRefresh(panel: *ra8.periph.eink.Panel, proto: anytype, pixels: u16) void {
    panelWord(panel, proto.preamble.command);
    panelWord(panel, @intFromEnum(proto.Command.load_area));
    for ([_]u16{ 0x0030, 0, 0, 2, 1, pixels }) |value| {
        panelWord(panel, proto.preamble.write);
        panelWord(panel, value);
    }
    panelWord(panel, proto.preamble.command);
    panelWord(panel, @intFromEnum(proto.Command.display_area));
    for ([_]u16{ 0, 0, 2, 1, 2 }) |value| {
        panelWord(panel, proto.preamble.write);
        panelWord(panel, value);
    }
}

fn panelWord(panel: *ra8.periph.eink.Panel, value: u16) void {
    _ = panel.exchange(@intCast(value >> 8));
    _ = panel.exchange(@intCast(value & 0xFF));
}

test "GIF output follows the sampled sequence when no PPM directory is requested" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "movie.gif" });
    defer std.testing.allocator.free(path);

    var sequence = try frames_out.Sequence.initOutputs(std.testing.allocator, null, path, 1);
    defer sequence.deinit();
    const first = [_]u32{0xFF00_0000};
    const second = [_]u32{0xFFFF_FFFF};
    try sequence.record(1, 1, &first, 0);
    try sequence.record(1, 1, &second, 20_000_000);
    try sequence.finish();
    try std.testing.expectEqual(@as(usize, 2), sequence.written);

    var file = try temp.dir.openFile("movie.gif", .{});
    defer file.close();
    var header: [6]u8 = undefined;
    try file.reader().readNoEof(&header);
    try std.testing.expectEqualSlices(u8, "GIF89a", &header);
}
