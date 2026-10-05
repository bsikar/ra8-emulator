//! The camera panel as one pane a window loop drives (RA8EMU-500): the
//! window's events go in, the panel is drawn into the frame, and between
//! emulation steps the CEU's source follows whatever the panel picked.
//!
//! It joins camera_view (drawing and clicks), camera_open (pick to source)
//! and camera_switch (swap in place) so the host shell needs three calls:
//! `handle` per event, `draw` per frame, `settle` between steps. It sees
//! only the platform seam's events, so the SDL window and the headless
//! one drive it the same way.
const std = @import("std");
const draw_list = @import("draw_list.zig");
const platform = @import("platform.zig");
const camera_panel = @import("camera_panel.zig");
const camera_view = @import("camera_view.zig");
const camera_open = @import("camera_open.zig");
const camera_switch = @import("camera_switch.zig");
const camera_devices = @import("camera_devices.zig");
const device_row = @import("camera_device_row.zig");
const FrameSource = camera_switch.FrameSource;

/// The button number SDL gives the primary (left) mouse button.
pub const primary_button: u8 = 1;

pub const Pane = struct {
    layout: camera_view.Layout,
    panel: camera_panel.Panel = .{},
    args: camera_open.Args = .{},
    switcher: camera_switch.Switcher = .{},
    /// The host's webcams, owned by whoever listed them; empty shows no row.
    devices: []const u32 = &.{},
    /// The webcam the device row picked; null opens the default one.
    device: ?u32 = null,

    /// Feeds one window event to the panel. Only a primary-button press is
    /// a click; returns whether the panel took the event, so the window
    /// does not also hand it to the board under the pane.
    pub fn handle(self: *Pane, event: platform.Event) bool {
        const press = switch (event) {
            .button => |button| button,
            else => return false,
        };
        if (!press.down or press.button != primary_button) return false;
        if (camera_view.click(&self.panel, self.layout, press.x, press.y)) return true;
        const picked = device_row.hit(device_row.Row.under(self.layout), self.devices, press.x, press.y);
        if (picked) |device| self.pickDevice(device);
        return picked != null;
    }

    /// Names the webcam to open. While the webcam is running, the new
    /// device counts as a switch so `settle` reopens it.
    pub fn pickDevice(self: *Pane, device: u32) void {
        if (self.device != null and self.device.? == device) return;
        self.device = device;
        if (self.panel.active == .webcam) self.panel.changes += 1;
    }

    pub fn draw(self: *const Pane, list: *draw_list.DrawList) !void {
        try camera_view.draw(list, self.layout, self.panel);
        try device_row.draw(list, device_row.Row.under(self.layout), self.devices, self.device);
    }

    /// Between emulation steps: when the panel switched, open its pick and
    /// put it where `source` points. A pick that will not open (nothing
    /// chosen yet, a file that will not read) leaves the running source.
    pub fn settle(
        self: *Pane,
        allocator: std.mem.Allocator,
        source: *FrameSource,
        format_control: *const u8,
    ) void {
        const changes = self.panel.changes;
        if (!self.switcher.due(changes)) return;
        var args = self.args;
        var device_buf: [4]u8 = undefined;
        if (self.device) |device| args.webcam = camera_devices.argument(&device_buf, device) catch unreachable;
        const next = camera_open.open(allocator, self.panel, args, format_control) catch {
            self.switcher.skip(changes);
            return;
        };
        self.switcher.apply(source, next, changes);
    }
};
