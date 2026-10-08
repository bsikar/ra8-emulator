//! Covers src/interfaces/cli/window_board.zig: the real board through the
//! host window loop shows what `--frame-out` would and hands the camera
//! pane the CEU's own source.
const std = @import("std");
const ra8 = @import("ra8");
const window_board = ra8.board.window_board;
const frame_out = ra8.board.report.frame_out;
const board_view = frame_out.board_view;
const host_loop = ra8.gui.host_loop;
const Headless = ra8.gui.headless.Headless;

const Counter = struct {
    left: u32,
    steps: u32 = 0,

    fn stepper(self: *Counter) window_board.Stepper {
        return .{ .ctx = self, .step = step };
    }

    fn step(ctx: *anyopaque) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.steps += 1;
        self.left -= 1;
        return self.left > 0;
    }
};

test "a board with no frame shows the dark default panel and its LEDs" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var counter = Counter{ .left = 1 };
    var screen = try window_board.Screen.init(std.testing.allocator, std.testing.io, &board, counter.stepper());
    defer screen.deinit();
    try std.testing.expect(!screen.frame);
    try std.testing.expectEqual(board_view.panel_width, screen.width);
    try std.testing.expectEqual(board_view.panel_height, screen.height);
    try std.testing.expectEqual(@as(u32, 0xFF000000), screen.pixels[0]);
    try std.testing.expectEqualDeep(frame_out.ledsOf(&board), screen.leds);
}

test "the camera pane gets the CEU's source and the sensor's format register" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var counter = Counter{ .left = 1 };
    var screen = try window_board.Screen.init(std.testing.allocator, std.testing.io, &board, counter.stepper());
    defer screen.deinit();
    const run = screen.run();
    const camera = run.vtable.camera(run.ctx).?;
    try std.testing.expectEqual(&board.capture.source, camera.source);
    try std.testing.expectEqual(&board.wire.sensor.format, camera.format_control);
}

test "the window loop steps the board until the stepper ends and presents the view" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var counter = Counter{ .left = 2 };
    var screen = try window_board.Screen.init(std.testing.allocator, std.testing.io, &board, counter.stepper());
    defer screen.deinit();
    var window = Headless.init(std.testing.allocator, 1280, 700);
    defer window.deinit();
    var loop = host_loop.Loop{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer loop.deinit();
    const run = screen.run();
    while (try loop.tick(window.platform(), run)) {}
    try std.testing.expectEqual(@as(u32, 2), counter.steps);
    // The board never changes, so only the first frame presents (RA8EMU-732).
    try std.testing.expectEqual(@as(u32, 1), window.presents);
    const shown = &window.last.?;
    try std.testing.expectEqual(host_loop.colorOf(0xFF000000), shown.at(board_view.margin, board_view.margin));
    try std.testing.expectEqual(host_loop.colorOf(board_view.pcb), shown.at(1, 1));
}

const tcon = ra8.periph.glcdc_tcon;

/// A 64x32 panel in the timing controller, so the window has one to scan.
fn programPanel(unit: *tcon.Tcon) void {
    _ = unit.latch(tcon.off.tim, 0);
    _ = unit.latch(tcon.off.stva1, 1);
    _ = unit.latch(tcon.off.stva2, @backingInt(tcon.Signal.stva) | tcon.field.invert);
    _ = unit.latch(tcon.off.stha1, 1);
    _ = unit.latch(tcon.off.stha2, @backingInt(tcon.Signal.de));
    _ = unit.latch(tcon.off.stvb1, 2 << tcon.field.start_shift | 32);
    _ = unit.latch(tcon.off.stvb2, @backingInt(tcon.Signal.stha) | tcon.field.invert);
    _ = unit.latch(tcon.off.sthb1, 2 << tcon.field.start_shift | 64);
    _ = unit.latch(tcon.off.sthb2, 0);
    _ = unit.latch(tcon.off.de, 0);
}

test "the window's scans leave the controller and its report as they were" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.domains = ra8.periph.pdctr.Domains.init(&board.protection);
    board.display = ra8.periph.glcdc.Glcdc.init(&board.domains.graphics);
    programPanel(&board.display.timing);
    try std.testing.expectEqual(@as(u32, 64), board.display.panelWidth());
    const before = board.display;
    var counter = Counter{ .left = 3 };
    var screen = try window_board.Screen.init(std.testing.allocator, std.testing.io, &board, counter.stepper());
    defer screen.deinit();
    var window = Headless.init(std.testing.allocator, 1280, 700);
    defer window.deinit();
    var loop = host_loop.Loop{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer loop.deinit();
    const run = screen.run();
    while (try loop.tick(window.platform(), run)) {}
    try std.testing.expectEqual(@as(u32, 3), counter.steps);
    try std.testing.expectEqual(@as(u32, 64), screen.width);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&board.display));
}

test "scanning on the engine leaves a step to read only what was handed over" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var counter = Counter{ .left = 5 };
    var screen = try window_board.Screen.init(std.testing.allocator, std.testing.io, &board, counter.stepper());
    defer screen.deinit();
    screen.on_engine = true;
    const run = screen.run();
    const first = run.vtable.board(run.ctx);
    try std.testing.expectEqual(@as(usize, screen.width) * screen.height, first.panel.len);
    try std.testing.expectEqualDeep(@as([]const board_view.Led, &frame_out.ledsOf(&board)), first.leds);
    try std.testing.expect(run.vtable.step(run.ctx));
    try std.testing.expectEqual(first.panel.ptr, run.vtable.board(run.ctx).panel.ptr);
    const hook = screen.parkHook();
    hook.call(hook.ctx);
    try std.testing.expect(run.vtable.step(run.ctx));
    try std.testing.expect(first.panel.ptr != run.vtable.board(run.ctx).panel.ptr);
}

test "a park hands the console what the channels sent, stamped with board time" {
    const sci = ra8.periph.sci;
    const console_feed = ra8.gui.console_feed;
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var counter = Counter{ .left = 1 };
    var screen = try window_board.Screen.init(std.testing.allocator, std.testing.io, &board, counter.stepper());
    defer screen.deinit();
    var feed = console_feed.Feed{ .allocator = std.testing.allocator, .io = std.testing.io, .now = screen.clock() };
    defer feed.deinit();
    screen.feed = &feed;
    board.serial.tap = feed.tap();
    var logs = @as([sci.channels]ra8.gui.console_log.Log, @splat(ra8.gui.console_log.Log.init(std.testing.allocator, 4)));
    defer for (&logs) |*log| log.deinit();
    board.serial.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.te);
    board.time.base.advance(board.time.base.hz);
    for ("boot\n") |byte| board.serial.write(sci.regAddress(sci.console_channel, sci.off_tdr), 4, byte);
    _ = try feed.drain(&logs);
    try std.testing.expectEqual(@as(usize, 0), logs[sci.console_channel].lines().len);
    const hook = screen.parkHook();
    hook.call(hook.ctx);
    _ = try feed.drain(&logs);
    const line = logs[sci.console_channel].lines()[0];
    try std.testing.expectEqualStrings("boot", line.text);
    try std.testing.expectEqual(board.time.base.now(), line.at_ns);
}
