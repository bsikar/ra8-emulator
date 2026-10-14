//! A window that answers every platform call and counts the ones a
//! decorator should pass through (video/capture.zig, window/stills.zig):
//! the tests check each call reaches it.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const platform_mod = gui_app.platform;
const raster = ra8.render.raster;
const draw_list = ra8.render.draw_list;

pub const Stub = struct {
    /// Whether `show` draws the list itself, as SDL geometry does.
    draws: bool = true,
    shows: u32 = 0,
    presents: u32 = 0,
    titled: [16]u8 = undefined,
    titled_len: usize = 0,
    toggles: u32 = 0,
    vsync: ?bool = null,
    hidden: bool = false,

    pub fn platform(self: *Stub) platform_mod.Platform {
        return .{ .ctx = self, .vtable = &.{
            .poll = poll,
            .size = size,
            .scale = scale,
            .present = present,
            .show = show,
            .interval = interval,
            .set_vsync = setVsync,
            .refresh = refresh,
            .appearance = appearance,
            .title = title,
            .toggle_fullscreen = toggleFullscreen,
            .fullscreen = fullscreen,
            .visible = visible,
            .position = position,
        } };
    }

    pub fn titleText(self: *const Stub) []const u8 {
        return self.titled[0..self.titled_len];
    }

    fn from(ctx: *anyopaque) *Stub {
        return @ptrCast(@alignCast(ctx));
    }
    fn poll(_: *anyopaque) ?platform_mod.Event {
        return null;
    }
    fn size(_: *anyopaque) platform_mod.Size {
        return .{ .width = 4, .height = 4 };
    }
    fn scale(_: *anyopaque) f32 {
        return 1;
    }
    fn present(ctx: *anyopaque, _: *const raster.Framebuffer) anyerror!void {
        from(ctx).presents += 1;
    }
    fn show(ctx: *anyopaque, _: *const draw_list.DrawList, _: ?raster.Atlas) anyerror!bool {
        const self = from(ctx);
        self.shows += 1;
        return self.draws;
    }
    fn interval(_: *anyopaque) u64 {
        return 7;
    }
    fn setVsync(ctx: *anyopaque, on: bool) bool {
        from(ctx).vsync = on;
        return on;
    }
    fn refresh(_: *anyopaque) u32 {
        return 144_000;
    }
    fn appearance(_: *anyopaque) platform_mod.Appearance {
        return .light;
    }
    fn title(ctx: *anyopaque, text: []const u8) void {
        const self = from(ctx);
        self.titled_len = @min(text.len, self.titled.len);
        @memcpy(self.titled[0..self.titled_len], text[0..self.titled_len]);
    }
    fn toggleFullscreen(ctx: *anyopaque) void {
        from(ctx).toggles += 1;
    }
    fn fullscreen(ctx: *anyopaque) bool {
        return from(ctx).toggles % 2 == 1;
    }
    fn visible(ctx: *anyopaque) bool {
        return !from(ctx).hidden;
    }
    fn position(_: *anyopaque) ?platform_mod.Pos {
        return .{ .x = 30, .y = 40 };
    }
};

/// Every call a decorator in front of `stub` should pass through reaches it.
pub fn expectPassesThrough(shown: platform_mod.Platform, stub: *Stub) !void {
    shown.title("ra8 emulator");
    try std.testing.expectEqualStrings("ra8 emulator", stub.titleText());
    try std.testing.expect(!shown.fullscreen());
    shown.toggleFullscreen();
    try std.testing.expectEqual(@as(u32, 1), stub.toggles);
    try std.testing.expect(shown.fullscreen());
    try std.testing.expect(shown.visible());
    stub.hidden = true;
    try std.testing.expect(!shown.visible());
    try std.testing.expectEqual(platform_mod.Pos{ .x = 30, .y = 40 }, shown.position().?);
    try std.testing.expect(shown.setVsync(true));
    try std.testing.expectEqual(@as(?bool, true), stub.vsync);
    try std.testing.expect(!shown.setVsync(false));
    try std.testing.expectEqual(@as(?bool, false), stub.vsync);
    try std.testing.expectEqual(@as(u32, 144_000), shown.refresh());
    try std.testing.expectEqual(@as(u64, 7), shown.interval());
    try std.testing.expectEqual(platform_mod.Appearance.light, shown.appearance());
}
