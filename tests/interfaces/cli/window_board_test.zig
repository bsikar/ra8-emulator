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
    var screen = try window_board.Screen.init(std.testing.allocator, &board, counter.stepper());
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
    var screen = try window_board.Screen.init(std.testing.allocator, &board, counter.stepper());
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
    var screen = try window_board.Screen.init(std.testing.allocator, &board, counter.stepper());
    defer screen.deinit();
    var window = Headless.init(std.testing.allocator, 1280, 700);
    defer window.deinit();
    var loop = host_loop.Loop{ .allocator = std.testing.allocator };
    defer loop.deinit();
    const run = screen.run();
    while (try loop.tick(window.platform(), run)) {}
    try std.testing.expectEqual(@as(u32, 2), counter.steps);
    try std.testing.expectEqual(@as(u32, 2), window.presents);
    const shown = &window.last.?;
    try std.testing.expectEqual(host_loop.colorOf(0xFF000000), shown.at(board_view.margin, board_view.margin));
    try std.testing.expectEqual(host_loop.colorOf(board_view.pcb), shown.at(1, 1));
}
