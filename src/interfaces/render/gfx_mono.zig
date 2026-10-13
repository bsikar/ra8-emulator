//! The shell's mono face (RA8EMU-1169): a second 8x16 cell face for the
//! debugger's dense panes (registers, memory, disassembly), so digits line
//! up and count at a glance. Labels, buttons and chrome keep the sans face.
//!
//! The bitmaps live in gfx_mono_data.zig (from unscii-16, public domain).
//! The glyphs expand into the shared font atlas below the sans rows
//! (RA8EMU-1145), so one raster pass draws both faces; the atlas grows in
//! gfx_font.zig. Cells are addressed in that combined atlas.
const data = @import("gfx_mono_data.zig");
const draw_list = @import("draw_list.zig");

pub const data_bits = data;

pub const glyph_w: u32 = data.geometry.width;
pub const glyph_h: u32 = data.geometry.height;
pub const first: u8 = data.geometry.first_codepoint;
pub const last: u8 = data.geometry.last_codepoint;
const per_row: u32 = 16;

/// Top of the mono block inside the combined atlas, in pixels: below the
/// sans face's six rows of cells.
pub const origin_y: u32 = 6 * glyph_h;

pub const Cell = struct { x: u32, y: u32 };

/// The cell for `char` in the combined atlas; anything outside printable
/// ASCII shows as '?'.
pub fn cell(char: u8) Cell {
    const shown = if (char < first or char > last) '?' else char;
    const index: u32 = shown - first;
    return .{ .x = index % per_row * glyph_w, .y = origin_y + index / per_row * glyph_h };
}

/// Pixels `len` characters take across.
pub fn textWidth(len: usize) u32 {
    return @intCast(len * glyph_w);
}

/// The longest start of `text` that fits in `max_px` pixels across.
pub fn fit(text: []const u8, max_px: u32) []const u8 {
    return text[0..@min(text.len, max_px / glyph_w)];
}

/// Adds `text` to the list with its top-left at (`x`, `y`), one glyph per
/// character; spaces add nothing.
pub fn draw(list: *draw_list.DrawList, x: i32, y: i32, text: []const u8, color: draw_list.Color) !void {
    for (text, 0..) |char, index| {
        if (char == ' ') continue;
        const at = cell(char);
        const left = x + @as(i32, @intCast(index * glyph_w));
        try list.glyph(.{ .x = left, .y = y, .w = glyph_w, .h = glyph_h }, at.x, at.y, color);
    }
}
