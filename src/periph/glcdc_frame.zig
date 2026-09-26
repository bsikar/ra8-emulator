//! The framebuffer descriptor a graphics layer's registers describe, and
//! the RAM it is allowed to live in.
//!
//! Split out of glcdc.zig, which is about the register window: this is about
//! the thing the window describes. A descriptor whose BASE is outside every
//! RAM window on the board is not a framebuffer however well formed the rest
//! of it reads, and a descriptor whose last line runs past the end of the
//! window it started in is the failure the scan refuses on.
const pixel = @import("glcdc_pixel.zig");
const scan = @import("glcdc_scan.zig");

/// A RAM window a framebuffer may legally live in on this board.
pub const Window = struct { base: u32, end: u32 };

/// Data TCM, on-chip SRAM and the external SDRAM the display examples draw
/// into. A base outside all three is not a framebuffer, whatever FLMRD says.
pub const ram_windows = [_]Window{
    .{ .base = 0x2000_0000, .end = 0x2001_0000 },
    .{ .base = 0x2200_0000, .end = 0x2220_0000 },
    .{ .base = 0x6800_0000, .end = 0x6C00_0000 },
};

/// Sanity cap on a decoded dimension, so a half-programmed layer does not
/// read back as a plausible 60000-pixel-wide panel.
pub const max_dimension: u32 = 4096;

/// What the panel is being scanned from, recovered from one layer's
/// registers.
pub const Framebuffer = struct {
    base: u32,
    width: u32,
    height: u32,
    stride: u32,
    format: pixel.Format,
    /// 1 or 2: which graphics layer is fetching.
    layer: u8,
    /// Whether the output stage (BG_EN.EN) is on behind it.
    enabled: bool,
};

/// The scan's view of a descriptor: the same framebuffer, said in the terms
/// the scanner works in (bits per pixel, the decoder, where the RAM window
/// the base sits in ends).
pub fn shapeOf(frame: Framebuffer) scan.Shape {
    return .{
        .base = frame.base,
        .width = frame.width,
        .height = frame.height,
        .stride = frame.stride,
        .bits = frame.format.bits(),
        .decode = frame.format.decoder(),
        .indexed = frame.format.indexed(),
        .window_end = windowEnd(frame.base),
    };
}

/// Where the RAM window an address sits in ends, or null when it sits in
/// none. The descriptor decode only asks whether the BASE is in RAM; a
/// framebuffer whose base is fine and whose last line is past the end of
/// the window is the failure this answers.
pub fn windowEnd(address: u32) ?u32 {
    for (ram_windows) |window| {
        if (address >= window.base and address < window.end) return window.end;
    }
    return null;
}

/// Whether an address points into a RAM window a framebuffer can live in.
pub fn addressIsRam(address: u32) bool {
    for (ram_windows) |window| {
        if (address >= window.base and address < window.end) return true;
    }
    return false;
}
