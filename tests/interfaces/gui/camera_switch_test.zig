//! Covers src/interfaces/gui/camera_switch.zig: the CEU's source follows the camera
//! panel mid-run, closing the old source as the new one goes in.
const std = @import("std");
const ra8 = @import("ra8");
const Switcher = ra8.gui.camera_switch.Switcher;
const FrameSource = ra8.gui.camera_switch.FrameSource;
const Panel = ra8.gui.camera_panel.Panel;
const Ceu = ra8.periph.ceu.Ceu;

const Fake = struct {
    closed: u32 = 0,

    fn source(self: *Fake, label: []const u8) FrameSource {
        return .{ .context = self, .vtable = &vtable, .label = label };
    }

    const vtable = FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

    fn frame(_: *anyopaque, _: u64, _: ra8.periph.ceu.camera.frame_source.Shape) void {}

    fn fill(_: *anyopaque, _: u32, _: u32, out: []u8) void {
        @memset(out, 0xA5);
    }

    fn close(context: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
};

test "nothing is due until the panel switches" {
    var panel = Panel{};
    const switcher = Switcher{};
    try std.testing.expect(!switcher.due(panel.changes));
    panel.pick(.webcam);
    try std.testing.expect(!switcher.due(panel.changes));
    panel.answer(.cancel);
    try std.testing.expect(!switcher.due(panel.changes));
}

test "apply closes the old source and installs the new one on the CEU" {
    var ceu = Ceu.init();
    var panel = Panel{};
    var switcher = Switcher{};
    var image = Fake{};
    panel.pick(.image);
    try std.testing.expect(switcher.due(panel.changes));
    switcher.apply(&ceu.source, image.source("still image"), panel.changes);
    try std.testing.expectEqualStrings("still image", ceu.source.label);
    try std.testing.expect(!switcher.due(panel.changes));
    var out: [4]u8 = undefined;
    ceu.source.fill(0, 0, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0xA5, 0xA5, 0xA5, 0xA5 }, &out);
}

test "switching again releases the source it replaces" {
    var ceu = Ceu.init();
    var panel = Panel{};
    var switcher = Switcher{};
    var image = Fake{};
    var video = Fake{};
    panel.pick(.image);
    switcher.apply(&ceu.source, image.source("still image"), panel.changes);
    panel.pick(.video);
    switcher.apply(&ceu.source, video.source("video"), panel.changes);
    try std.testing.expectEqual(@as(u32, 1), image.closed);
    try std.testing.expectEqual(@as(u32, 0), video.closed);
    try std.testing.expectEqualStrings("video", ceu.source.label);
}

test "a switch that will not open keeps the running source" {
    var ceu = Ceu.init();
    var panel = Panel{};
    var switcher = Switcher{};
    var image = Fake{};
    panel.pick(.image);
    switcher.apply(&ceu.source, image.source("still image"), panel.changes);
    panel.pick(.video);
    switcher.skip(panel.changes);
    try std.testing.expect(!switcher.due(panel.changes));
    try std.testing.expectEqual(@as(u32, 0), image.closed);
    try std.testing.expectEqualStrings("still image", ceu.source.label);
}
