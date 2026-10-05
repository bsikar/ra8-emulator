//! Covers src/gui/host_loop.zig: a short run through the headless window
//! presents the board view and the camera pane, stops when the run ends or
//! the window closes, and lets a click on the pane swap the camera source.
const std = @import("std");
const ra8 = @import("ra8");
const host_loop = ra8.gui.host_loop;
const board_view = host_loop.board_view;
const view = ra8.gui.camera_view;
const FrameSource = ra8.gui.camera_switch.FrameSource;
const Headless = ra8.gui.headless.Headless;

const red: u32 = 0xFFFF0000;

const Fake = struct {
    panel: [4]u32 = .{ red, red, red, red },
    leds: [1]board_view.Led = .{.{ .rgb565 = 0x07E0, .on = true }},
    steps_left: u32 = 3,
    steps: u32 = 0,
    closed: u32 = 0,
    source: FrameSource = undefined,
    format: u8 = 0,

    fn run(self: *Fake) host_loop.Run {
        self.source = .{ .context = self, .vtable = &source_vtable, .label = "fake" };
        return .{ .ctx = self, .vtable = &.{ .step = step, .board = board, .camera = camera } };
    }

    fn step(ctx: *anyopaque) bool {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.steps += 1;
        self.steps_left -= 1;
        return self.steps_left > 0;
    }

    fn board(ctx: *anyopaque) host_loop.Board {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return .{ .panel = &self.panel, .width = 2, .height = 2, .leds = &self.leds };
    }

    fn camera(ctx: *anyopaque) ?host_loop.Camera {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return .{ .source = &self.source, .format_control = &self.format };
    }

    const source_vtable = FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

    fn frame(_: *anyopaque, _: u64, _: ra8.periph.ceu.camera.frame_source.Shape) void {}

    fn fill(_: *anyopaque, _: u32, _: u32, out: []u8) void {
        @memset(out, 0);
    }

    fn close(context: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
};

fn layout() view.Layout {
    return host_loop.paneLayout(board_view.size(2, 2));
}

fn press(at: ra8.gui.draw_list.Rect) ra8.gui.platform.Event {
    return .{ .button = .{ .button = 1, .down = true, .x = at.x + 1, .y = at.y + 1 } };
}

test "a frame shows the board view with the camera pane beside it" {
    var window = Headless.init(std.testing.allocator, 256, 128);
    defer window.deinit();
    var fake = Fake{};
    var loop = host_loop.Loop{ .allocator = std.testing.allocator };
    defer loop.deinit();
    try std.testing.expect(try loop.tick(window.platform(), fake.run()));
    const shown = &window.last.?;
    try std.testing.expectEqual(host_loop.colorOf(red), shown.at(board_view.margin, board_view.margin));
    try std.testing.expectEqual(host_loop.colorOf(board_view.pcb), shown.at(1, 1));
    const gradient = layout().source(.gradient);
    const x: u32 = @intCast(gradient.x + 4);
    const y: u32 = @intCast(gradient.y + 4);
    try std.testing.expectEqual(view.colorOf(.gradient), shown.at(x, y));
    try std.testing.expectEqual(host_loop.background, shown.at(250, 120));
}

test "the loop runs until the run ends, presenting every frame" {
    var window = Headless.init(std.testing.allocator, 256, 128);
    defer window.deinit();
    var fake = Fake{};
    var loop = host_loop.Loop{ .allocator = std.testing.allocator };
    defer loop.deinit();
    const run = fake.run();
    while (try loop.tick(window.platform(), run)) {}
    try std.testing.expectEqual(@as(u32, 3), fake.steps);
    try std.testing.expectEqual(@as(u32, 3), window.presents);
}

test "closing the window stops before the next slice runs" {
    var window = Headless.init(std.testing.allocator, 256, 128);
    defer window.deinit();
    var fake = Fake{};
    var loop = host_loop.Loop{ .allocator = std.testing.allocator };
    defer loop.deinit();
    try window.feed(.quit);
    try std.testing.expect(!try loop.tick(window.platform(), fake.run()));
    try std.testing.expectEqual(@as(u32, 0), fake.steps);
    try std.testing.expectEqual(@as(u32, 0), window.presents);
}

test "a click on the camera pane swaps the CEU's source before the next slice" {
    var window = Headless.init(std.testing.allocator, 256, 128);
    defer window.deinit();
    var fake = Fake{ .steps_left = 10 };
    var loop = host_loop.Loop{ .allocator = std.testing.allocator };
    defer loop.deinit();
    const run = fake.run();
    try window.feed(press(layout().source(.video)));
    _ = try loop.tick(window.platform(), run);
    try std.testing.expectEqual(@as(u32, 0), fake.closed);
    try std.testing.expectEqualStrings("fake", fake.source.label);
    try window.feed(press(layout().source(.gradient)));
    _ = try loop.tick(window.platform(), run);
    defer fake.source.close();
    try std.testing.expectEqual(@as(u32, 1), fake.closed);
    try std.testing.expectEqualStrings("synthetic gradient", fake.source.label);
}

test "a resized window gets a frame of its new size" {
    var window = Headless.init(std.testing.allocator, 256, 128);
    defer window.deinit();
    var fake = Fake{ .steps_left = 10 };
    var loop = host_loop.Loop{ .allocator = std.testing.allocator };
    defer loop.deinit();
    const run = fake.run();
    _ = try loop.tick(window.platform(), run);
    try window.feed(.{ .resize = .{ .width = 300, .height = 140 } });
    _ = try loop.tick(window.platform(), run);
    try std.testing.expectEqual(@as(u32, 300), window.last.?.width);
    try std.testing.expectEqual(@as(u32, 140), window.last.?.height);
}

test "the pane offers the webcams the loop adopted, and the loop frees them" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{ "video4", "video1" }) |name| (try tmp.dir.createFile(name, .{})).close();
    var loop = host_loop.Loop{ .allocator = std.testing.allocator };
    defer loop.deinit();
    loop.adoptDevices(try ra8.gui.camera_devices.list(std.testing.allocator, tmp.dir));
    try std.testing.expectEqualSlices(u32, &.{ 1, 4 }, loop.pane.devices);
    loop.adoptDevices(try ra8.gui.camera_devices.list(std.testing.allocator, tmp.dir));
    try std.testing.expectEqual(@as(usize, 2), loop.pane.devices.len);
}

test "Always answered in the window is kept for the project's next run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var window = Headless.init(std.testing.allocator, 256, 128);
    defer window.deinit();
    var fake = Fake{ .steps_left = 10 };
    var loop = host_loop.Loop{ .allocator = std.testing.allocator };
    defer loop.deinit();
    loop.useProject(tmp.dir);
    try std.testing.expect(!loop.pane.panel.always);
    try window.feed(press(layout().source(.webcam)));
    _ = try loop.tick(window.platform(), fake.run());
    try std.testing.expect(!ra8.gui.camera_consent_store.load(tmp.dir));
    try window.feed(press(layout().dialog(.always)));
    _ = try loop.tick(window.platform(), fake.run());
    try std.testing.expect(ra8.gui.camera_consent_store.load(tmp.dir));
    var next = host_loop.Loop{ .allocator = std.testing.allocator };
    defer next.deinit();
    next.useProject(tmp.dir);
    try std.testing.expect(next.pane.panel.always);
}
