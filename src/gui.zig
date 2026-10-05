//! The GUI's shared layer (RA8EMU-202, ADR docs/adr/0001-gui-stack.md).
pub const draw_list = @import("gui/draw_list.zig");
pub const raster = @import("gui/raster.zig");
pub const platform = @import("gui/platform.zig");
pub const headless = @import("gui/headless.zig");
pub const camera_panel = @import("gui/camera_panel.zig");
pub const camera_switch = @import("gui/camera_switch.zig");
pub const camera_open = @import("gui/camera_open.zig");
