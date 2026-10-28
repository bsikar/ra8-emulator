//! Covers src/session/harness/picture.zig: the checkpoint picture source
//! composes the panel purely (no frame counted, no scan raised), answers
//! the gray of what the display shows stamped with the checkpoint's
//! position and the board's time, and answers null while the display
//! shows nothing.
const std = @import("std");
const ra8 = @import("ra8");
const store_board = @import("../interfaces/cli/store_board.zig");

const picture = ra8.session.harness_picture;
const crop = ra8.session.history_frame_crop;
const Board = ra8.board.board.Board;
const Files = ra8.session.board.state.Files;
const glcdc = ra8.chip.periph.glcdc;
const tcon = ra8.chip.periph.glcdc.tcon;
const glcdc_sys = ra8.chip.periph.glcdc.sys;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;

const gpa = std.testing.allocator;

fn showPanel(board: *Board, argb: u32) void {
    board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
    board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 2);
    board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 1);
    board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, argb);
}

test "the source answers the gray panel at the checkpoint without counting a frame" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    var board = Board.init(gpa);
    defer board.deinit();
    try store_board.attach(&board, .{ .store = &store });
    showPanel(&board, 0xFF11_2233);
    var files: Files = undefined;
    files.board = &board;

    const frames = board.display.system.frames;
    const at: ra8.session.history_checkpoint_picture.Position = .{ .r = 9, .phase = .cpu1, .o = 3, .gap = .polled };
    var shown = (try picture.source(&files).lastScan(gpa, at)).?;
    defer shown.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 2), shown.width);
    try std.testing.expectEqual(@as(u16, 1), shown.height);
    const want = crop.argbToGray(0xFF11_2233);
    try std.testing.expectEqualSlices(u8, &.{ want, want }, shown.pixels);
    try std.testing.expectEqual(at, shown.position);
    try std.testing.expectEqual(board.time.base.now(), shown.virtual_ns);
    // Pure: asking twice, or at all, never scans.
    var again = (try picture.source(&files).lastScan(gpa, at)).?;
    defer again.deinit(gpa);
    try std.testing.expectEqual(frames, board.display.system.frames);
    try std.testing.expectEqualSlices(u8, shown.pixels, again.pixels);
}

test "a display that shows nothing has no picture" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    var board = Board.init(gpa);
    defer board.deinit();
    try store_board.attach(&board, .{ .store = &store });
    var files: Files = undefined;
    files.board = &board;
    try std.testing.expectEqual(@as(?ra8.session.history_checkpoint_picture.Decoded, null), try picture.source(&files).lastScan(gpa, .{}));
}
