//! ra8_render: drawing and encoding with no window and no host (ADR 0004
//! sections 2 and 3, knowledge base article RA8EMU-A-2; under
//! src/interfaces since RA8EMU-1096, because only the cli and the gui use
//! it). The draw list, the rasterizer, the font, geometry, widget paint, the
//! board-view composition `--frame-out` and the GUI share, and the PNG, GIF
//! and WAV encoders. It imports the session's value types and the firmware's
//! widget library. Every encoder writes to a writer it is given.
pub const draw_list = @import("draw_list.zig");
pub const raster = @import("raster.zig");
pub const font = @import("gfx_font.zig");
pub const geometry = @import("geometry.zig");
pub const widget_paint = @import("widget_paint.zig");
pub const paint_backend = @import("paint_backend.zig");
pub const board_view = @import("board_view.zig");
pub const png = @import("png.zig");
pub const gif = @import("gif/gif.zig");
pub const wav = @import("wav.zig");

// Every binary that compiles this library must carry the widget ABI's
// extern symbols (RA8EMU-1173): widget_paint exports ra8_log_emit_error and
// comptime-links the firmware's host package exports (RA8FW-828), so a
// raster-path-only user such as the gui geometry test links too.
comptime {
    _ = widget_paint;
    _ = @import("ra8_widget_host");
}
