//! Covers src/interfaces/cli/zig_run.zig: the board's side of a Zig-core
//! boundary.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const zig_run = ra8.board.zig_run;
const profile = ra8.core.functions.profile;
const profile_report = ra8.board.report.profile;
const cpu_boot = ra8.core.cpu.boot;
const symbols = ra8.core.symbols;
const Builder = @import("../../debug/symbol_image.zig").Builder;

test "a boundary is the chunk until SysTick is armed, then its period" {
    var core = try ra8.core.engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&core);
    var timebase: ra8.periph.clocks.Clocks = .{ .per_chunk = 5000 };
    var clock: zig_run.Clock = .{ .memory = .{ .engine = core }, .board = &board, .timebase = &timebase };
    try std.testing.expectEqual(@as(u32, 5000), clock.width());
    try core.writeWord(memmap.syst.rvr, 999);
    try core.writeWord(memmap.syst.csr, 0x7);
    try std.testing.expectEqual(@as(u32, 1000), clock.width());
    try core.writeWord(memmap.syst.rvr, 99_999);
    try std.testing.expectEqual(@as(u32, 5000), clock.width());
}

test "closing a boundary charges the clocks and wraps SysTick into ICSR" {
    var core = try ra8.core.engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&core);
    var timebase: ra8.periph.clocks.Clocks = .{ .per_chunk = 5000 };
    var clock: zig_run.Clock = .{ .memory = .{ .engine = core }, .board = &board, .timebase = &timebase };
    try clock.close(7);
    try std.testing.expectEqual(@as(u64, 7), timebase.elapsed);
    try core.writeWord(memmap.syst.rvr, 9);
    try core.writeWord(memmap.syst.cvr, 0);
    try core.writeWord(memmap.syst.csr, 0x7);
    try clock.close(10);
    try std.testing.expectEqual(@as(u64, 17), timebase.elapsed);
    try std.testing.expect(timebase.ticks > 0);
}

fn profileInstruction(context: *anyopaque, address: u32) void {
    const table: *profile.Table = @ptrCast(@alignCast(context));
    table.instruction(address);
}

test "a Zig core run profiles retired function instructions and writes folded output" {
    const base = memmap.sram_base;
    var core = try ra8.core.engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try core.writeWord(base, memmap.sram_end);
    try core.writeWord(base + 4, base + 9);
    try core.writeWord(base + 8, 0xBF00_BF00);
    try core.writeWord(base + 12, 0xBF00_BF00);

    var image_bytes: [512]u8 = undefined;
    const encoded = Builder.build(&image_bytes, &.{"profiled_function"}, &.{base + 9});
    const symbol: *align(1) symbols.Symbol = std.mem.bytesAsValue(symbols.Symbol, encoded[Builder.sym_off..][0..@sizeOf(symbols.Symbol)]);
    symbol.st_info = symbols.symbol_type.func;
    symbol.st_size = 8;
    const image = try ra8.core.elf.Image.init(encoded);
    var table: profile.Table = .{ .image = image };
    table.prepare();

    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try board.attach(&core);
    var ran: u64 = 0;
    var output: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&output);
    const listener: ra8.core.cpu.cpu.RetireListener = .{ .context = &table, .instructionFn = profileInstruction };
    const status = try cpu_boot.start(stream.writer(), .zig, image, .{ .engine = core }, &board.bus, base, 3, &ran, .{ .retire_listener = listener });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u64, 3), ran);
    var rows: [profile.limits.functions]profile.Site = undefined;
    const ranked = table.ranked(&rows);
    try std.testing.expectEqual(@as(usize, 1), ranked.len);
    try std.testing.expectEqual(base + 8, ranked[0].address);
    try std.testing.expectEqual(@as(u64, 3), ranked[0].instructions);
    try std.testing.expectEqual(@as(u64, 3), ranked[0].cycles);

    const summary_path = ".ra8-profile-zig-run-test.out";
    const folded_path = ".ra8-profile-zig-run-test.folded";
    defer std.fs.cwd().deleteFile(summary_path) catch {};
    defer std.fs.cwd().deleteFile(folded_path) catch {};
    var summary = try std.fs.cwd().createFile(summary_path, .{ .truncate = true });
    defer summary.close();
    try profile_report.write(summary.writer(), image, table, folded_path);
    const folded = try std.fs.cwd().readFileAlloc(std.testing.allocator, folded_path, 128);
    defer std.testing.allocator.free(folded);
    try std.testing.expectEqualStrings("profiled_function 3\n", folded);
}
