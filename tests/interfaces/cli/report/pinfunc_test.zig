const std = @import("std");
const ra8 = @import("ra8");
const pinfunc = @import("cli_app").report.pinfunc;
const pfs = ra8.chip.periph.pfs;
const gpio = ra8.chip.periph.gpio;

fn render(board: *ra8.board.board.Board) !std.Io.Writer.Allocating {
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer text.deinit();
    try pinfunc.sections(board, &text.writer);
    return text;
}

test "an untouched pin block adds no report" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var text = try render(&board);
    defer text.deinit();
    try std.testing.expectEqual(@as(usize, 0), text.written().len);
}

test "PFS direction refusal is distinct from missing write protection unlock" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    const at = pfs.Pfs.pinAddress(2, 0);
    board.pinfunc.guard.write(pfs.protect.off.pwprs, 0);
    board.pinfunc.guard.write(pfs.protect.off.pwprs, pfs.protect.field.pfswe);
    board.pinfunc.write(at, 4, 4);
    var text = try render(&board);
    defer text.deinit();
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "PFS: REFUSED direction in 1 write(s), unsupported by the pad\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "PWPRS.PFSWE was never set") == null);
}

test "GPIO-only direction refusal is reported even when PFS is quiet" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.pins.applyWrite(gpio.regAddress(2, gpio.pcntr1), 4, 1);
    var text = try render(&board);
    defer text.deinit();
    try std.testing.expectEqualStrings(
        "PFS: 0 pin function write(s) landed\nGPIO: REFUSED direction in 1 write(s), unsupported by the pad\n",
        text.written(),
    );
}
