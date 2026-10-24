//! Tests for src/interfaces/gui/ui/fork_banner.zig (Slice 20.4 fork confirmation banner).
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const fork_banner = gui_app.fork_banner;
const draw_list = ra8.render.draw_list;

const Rect = draw_list.Rect;

test "fork banner layout and hit testing" {
    const banner = Rect{ .x = 0, .y = 20, .w = 800, .h = fork_banner.height };

    const ok_box = fork_banner.buttonConfirm(banner);
    const cancel_box = fork_banner.buttonCancel(banner);

    // Confirm button hit
    const hit_ok = fork_banner.hit(banner, ok_box.x + 5, ok_box.y + 5);
    try std.testing.expectEqual(fork_banner.Action.confirm, hit_ok);

    // Cancel button hit
    const hit_cancel = fork_banner.hit(banner, cancel_box.x + 5, cancel_box.y + 5);
    try std.testing.expectEqual(fork_banner.Action.cancel, hit_cancel);

    // Outside buttons hit
    const hit_none = fork_banner.hit(banner, banner.x + 10, banner.y + 5);
    try std.testing.expectEqual(fork_banner.Action.none, hit_none);

    // Outside banner
    const hit_out = fork_banner.hit(banner, banner.x + 10, banner.y - 10);
    try std.testing.expectEqual(fork_banner.Action.none, hit_out);
}
