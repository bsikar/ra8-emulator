//! The GUI's shared layer (RA8EMU-202, ADR docs/adr/0001-gui-stack.md).
pub const draw_list = @import("gui/draw_list.zig");
pub const raster = @import("gui/raster.zig");
pub const platform = @import("gui/platform.zig");
pub const headless = @import("gui/headless.zig");
pub const camera_panel = @import("gui/camera_panel.zig");
pub const camera_switch = @import("gui/camera_switch.zig");
pub const camera_open = @import("gui/camera_open.zig");
pub const camera_devices = @import("gui/camera_devices.zig");
pub const camera_consent_store = @import("gui/camera_consent_store.zig");
pub const camera_media = @import("gui/camera_media.zig");
pub const camera_view = @import("gui/camera_view.zig");
pub const camera_pane = @import("gui/camera_pane.zig");
pub const camera_device_row = @import("gui/camera_device_row.zig");
pub const camera_media_row = @import("gui/camera_media_row.zig");
pub const host_loop = @import("gui/host_loop.zig");
