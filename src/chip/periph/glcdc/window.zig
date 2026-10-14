//! The GLCDC register window: its base and span, the offsets inside it,
//! and the field masks the block reads. One map for the block and for a
//! caller that only knows it, re-exported through glcdc.zig.
const frame = @import("frame.zig");
const pixel = @import("pixel.zig");

pub const win_base: u32 = 0x4034_2000;
pub const win_span: u32 = 0x1500;
/// Register byte offsets inside the window (ra8_glcdc_regs.h).
pub const off = struct {
    /// BG_EN: background-plane operation enable, the output stage.
    pub const bg_en: u32 = 0x1000;
    /// Where graphics layer 1 starts. Layer 2 sits one stride above it.
    pub const layer_base: u32 = 0x1100;
    pub const layer_stride: u32 = 0x100;
    /// Offsets within one layer.
    pub const flmrd: u32 = 0x04;
    pub const flm2: u32 = 0x0C;
    pub const flm3: u32 = 0x10;
    pub const flm5: u32 = 0x18;
    pub const flm6: u32 = 0x1C;
    /// CLUTINT: which CLUT plane this layer's fetch unit reads.
    pub const clutint: u32 = 0x50;
    /// BG.BGC: the background colour under both graphics layers.
    pub const bg_bgc: u32 = 0x1014;
};
/// Field masks this file reads. The FLM field positions the descriptor
/// decode applies live with the decode, in frame.zig.
pub const field = struct {
    /// BG_EN.EN, bit 0: the output stage is running.
    pub const bg_en: u32 = 0x1;
    /// FLMRD.RENB, bit 0: this layer fetches from its framebuffer.
    pub const renb: u32 = frame.field.renb;
};
/// FLM6.FORMAT codes, and the decode behind them. Re-exported so a caller
/// that only knows the block still names the format through it.
pub const Format = pixel.Format;

/// The framebuffer descriptor and the RAM it may live in, re-exported so a
/// caller that only knows the block still reaches them through it.
pub const Framebuffer = frame.Framebuffer;
pub const Window = frame.Window;
pub const ram_windows = frame.ram_windows;
pub const max_dimension = frame.max_dimension;
pub const shapeOf = frame.shapeOf;
pub const windowEnd = frame.windowEnd;
pub const addressIsRam = frame.addressIsRam;
