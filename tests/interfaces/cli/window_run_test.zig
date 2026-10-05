//! Covers src/interfaces/cli/window_run.zig: a Zig-core run shown in a
//! headless window advances one frame per tick, ends the loop when the run
//! ends, ends the run when the window closes, and lets a click on the
//! camera pane swap the CEU source while the run goes on.
const std = @import("std");
const ra8 = @import("ra8");
const store_board = @import("store_board.zig");
const soaker = @import("soaker.zig");

const zig_run = ra8.board.zig_run;
const cpu_boot = ra8.core.cpu.boot;
const window_run = ra8.board.window_run;
const Pacer = ra8.board.window_pace.Pacer;
const Headless = ra8.gui.headless.Headless;

const per_frame: u64 = 20_000;

/// A soaker image on the Zig core with a paced clock.
const Soak = struct {
    store: store_board.Store,
    board: ra8.board.Board,
    timebase: ra8.periph.clocks.Clocks = .{ .per_chunk = 5_000 },
    pacer: Pacer = .{ .per_frame = per_frame },
    clock: zig_run.Clock = undefined,
    budget: u64,
    ran: u64 = 0,
    failed: bool = false,

    fn init(self: *Soak, budget: u64) !void {
        self.* = .{ .store = try store_board.Store.init(null), .board = ra8.board.Board.init(std.testing.allocator), .budget = budget };
        const core = self.guest();
        try soaker.load(core, false);
        try store_board.attach(&self.board, core);
        self.clock = .{ .memory = core, .board = &self.board, .timebase = &self.timebase, .pace = &self.pacer };
    }

    fn deinit(self: *Soak) void {
        self.board.deinit();
        self.store.deinit();
    }

    fn guest(self: *Soak) store_board.Guest {
        return .{ .store = &self.store };
    }

    fn engine(self: *Soak) window_run.Engine {
        return .{ .ctx = self, .run = run };
    }

    fn run(ctx: *anyopaque) void {
        const self: *Soak = @ptrCast(@alignCast(ctx));
        var final: cpu_boot.Regs = .{};
        var output: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&output);
        _ = cpu_boot.start(stream.writer(), .zig, self.guest(), &self.board.bus, soaker.base, self.budget, &self.ran, .{ .boundary = self.clock.boundary(), .final = &final }) catch {
            self.failed = true;
        };
    }
};

test "the window draws a frame per slice until the run ends" {
    var soak: Soak = undefined;
    try soak.init(100_000);
    defer soak.deinit();
    var window = Headless.init(std.testing.allocator, 1280, 700);
    defer window.deinit();
    const shown = try window_run.show(std.testing.allocator, window.platform(), &soak.board, &soak.pacer, soak.engine(), .{});
    try std.testing.expect(!soak.failed);
    try std.testing.expect(!shown.closed);
    try std.testing.expect(shown.frames >= 4);
    // The tick on which the run ends still draws, so the window is left
    // showing the board as the run left it.
    try std.testing.expectEqual(shown.frames + 1, window.presents);
    const board_view = ra8.board.report.frame_out.board_view;
    const panel_bytes = @as(usize, board_view.panel_width) * board_view.panel_height * @sizeOf(u32);
    try std.testing.expect(shown.snapshot_bytes >= panel_bytes);
    try std.testing.expectEqual(@as(u64, 0), shown.console_lost);
    try std.testing.expect(soak.board.serial.tap == null);
    // The soaker sleeps, so board time, not retired instructions, is what
    // a grant buys. The window no longer waits for each grant to be spent,
    // so a tick can draw without granting; at least one grant was.
    try std.testing.expect(soak.board.time.base.now() >= per_frame);
}

test "closing the window ends the run at its next boundary" {
    var soak: Soak = undefined;
    try soak.init(1_000_000_000);
    defer soak.deinit();
    var window = Headless.init(std.testing.allocator, 1280, 700);
    defer window.deinit();
    try window.feed(.quit);
    const shown = try window_run.show(std.testing.allocator, window.platform(), &soak.board, &soak.pacer, soak.engine(), .{});
    try std.testing.expect(!soak.failed);
    try std.testing.expect(shown.closed);
    try std.testing.expectEqual(@as(u32, 0), shown.frames);
    try std.testing.expectEqual(@as(u32, 0), window.presents);
    try std.testing.expect(soak.board.time.base.now() <= per_frame);
    try std.testing.expect(soak.clock.paced_out);
}

/// A camera source that counts how often the board let go of it.
const Held = struct {
    closed: u32 = 0,

    fn source(self: *Held) ra8.gui.camera_switch.FrameSource {
        return .{ .context = self, .vtable = &.{ .frame = frame, .fill = fill, .close = close }, .label = "held" };
    }

    fn frame(_: *anyopaque, _: u64, _: ra8.periph.ceu.camera.frame_source.Shape) void {}

    fn fill(_: *anyopaque, _: u32, _: u32, out: []u8) void {
        @memset(out, 0);
    }

    fn close(context: *anyopaque) void {
        const self: *Held = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
};

fn press(at: ra8.gui.draw_list.Rect) ra8.gui.platform.Event {
    return .{ .button = .{ .button = 1, .down = true, .x = at.x + 1, .y = at.y + 1 } };
}

test "a click on the camera pane swaps the CEU's source while the run goes on" {
    var soak: Soak = undefined;
    try soak.init(100_000);
    defer soak.deinit();
    var held = Held{};
    soak.board.capture.source = held.source();
    var window = Headless.init(std.testing.allocator, 1600, 700);
    defer window.deinit();
    const board_view = ra8.board.report.frame_out.board_view;
    const pane = ra8.gui.host_loop.paneLayout(board_view.size(board_view.panel_width, board_view.panel_height));
    // The pane starts on the gradient, so a pick away and back is a switch.
    try window.feed(press(pane.source(.video)));
    try window.feed(press(pane.source(.gradient)));
    const shown = try window_run.show(std.testing.allocator, window.platform(), &soak.board, &soak.pacer, soak.engine(), .{});
    defer soak.board.capture.source.close();
    try std.testing.expect(!soak.failed);
    try std.testing.expect(!shown.closed);
    try std.testing.expect(shown.frames >= 4);
    try std.testing.expectEqual(@as(u32, 1), held.closed);
    try std.testing.expectEqualStrings("synthetic gradient", soak.board.capture.source.label);
}
