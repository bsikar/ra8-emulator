//! GLCDC: the display controller, and where the panel is being scanned from.
//!
//! The RA8D2 graphics LCD controller sits at 0x4034_2000 (HUM Ch 63,
//! ra8_glcdc_regs.h). The display and e-reader examples program a graphics
//! layer with the address of the framebuffer they drew into, the stride of a
//! line, the number of lines and the pixel format, then set FLMRD.RENB to
//! start fetching and BG_EN.EN to turn the output stage on. Ported from
//! board_periph_glcdc.c on dev.
//!
//!   BG_EN     (+0x1000) EN b0: the background plane, the output stage gate
//!   GRn_FLMRD (+0x1104 / +0x1204) RENB b0: this layer is fetching pixels
//!   GRn_FLM2  (+0x110C / +0x120C) BASE: framebuffer address
//!   GRn_FLM3  (+0x1110 / +0x1210) LNOFF [31:16]: line stride in bytes
//!   GRn_FLM5  (+0x1118 / +0x1218) LNNUM [26:16]: lines - 1
//!   GRn_FLM6  (+0x111C / +0x121C) FORMAT [30:28]: pixel format
//!
//! The block is inside the switchable graphics power domain (HUM Ch 11.5.1
//! Table 11.7 p 480), which is gated off at reset, so it asks pdctr.zig
//! before answering with anything. That is the whole reason this slice is the
//! first one after the power domain: a display controller programmed while
//! its domain is dark is the shape of the C tree's issue #247.
const periph = @import("registry.zig");
const pdctr = @import("pdctr.zig");

/// GLCDC geometry. The span reaches past the graphics layers to the panel
/// clock control at +0x1450, which is the last register in the block.
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
};

/// Field masks and shifts the descriptor decode applies (HUM Ch 63).
pub const field = struct {
    /// BG_EN.EN, bit 0: the output stage is running.
    pub const bg_en: u32 = 0x1;
    /// FLMRD.RENB, bit 0: this layer fetches from its framebuffer.
    pub const renb: u32 = 0x1;
    pub const stride_shift: u5 = 16;
    pub const stride_mask: u32 = 0xFFFF;
    pub const lnnum_shift: u5 = 16;
    pub const lnnum_mask: u32 = 0x7FF;
    pub const format_shift: u5 = 28;
    pub const format_mask: u32 = 0x7;
};

/// FLM6.FORMAT codes (HUM Ch 63 Table 63.11). A real enumeration: these are
/// the eight pixel formats the fetch unit understands and nothing else.
pub const Format = enum(u3) {
    argb8888 = 0,
    rgb888 = 1,
    rgb565 = 2,
    argb1555 = 3,
    argb4444 = 4,
    clut8 = 5,
    clut4 = 6,
    clut1 = 7,

    /// Bytes fetched per pixel. The sub-byte CLUT modes round up to one,
    /// which is what the width recovery below needs and all it needs.
    pub fn bytesPerPixel(self: Format) u32 {
        return switch (self) {
            .argb8888, .rgb888 => 4,
            .rgb565, .argb1555, .argb4444 => 2,
            .clut8, .clut4, .clut1 => 1,
        };
    }
};

/// A RAM window a framebuffer may legally live in on this board.
const Window = struct { base: u32, end: u32 };

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
    format: Format,
    /// 1 or 2: which graphics layer is fetching.
    layer: u8,
    /// Whether the output stage (BG_EN.EN) is on behind it.
    enabled: bool,
};

const words = win_span / 4;

/// The display controller: the register window, the power domain it lives
/// in, and the counters behind the end-of-run line.
pub const Glcdc = struct {
    /// The domain gate, held as a pointer so the answer is the board's live
    /// PDCTRGD rather than a copy of it taken at construction.
    domain: *const pdctr.Pdctr,
    registers: [words]u32 = [_]u32{0} ** words,
    /// Writes accepted into the register window.
    writes: u32 = 0,
    /// Writes discarded because the graphics domain was gated off.
    dropped_unpowered: u32 = 0,
    /// Reads answered with zero for the same reason.
    dark_reads: u32 = 0,
    /// Times a layer's FLMRD.RENB went from clear to set.
    starts: u32 = 0,

    pub fn init(domain: *const pdctr.Pdctr) Glcdc {
        return .{ .domain = domain };
    }

    /// A run that never touched the block has nothing to narrate.
    pub fn quiet(self: *const Glcdc) bool {
        return self.writes == 0 and self.dropped_unpowered == 0 and self.dark_reads == 0;
    }

    /// BG_EN.EN: the output stage. A layer can be fetching with this clear,
    /// and the panel stays blank.
    pub fn outputEnabled(self: *const Glcdc) bool {
        return self.word(off.bg_en) & field.bg_en != 0;
    }

    /// The framebuffer being scanned out, or null when neither layer is
    /// fetching from something that looks like one. Layer 1 is the upper
    /// layer the display examples draw into, so it wins when both are up.
    pub fn framebuffer(self: *const Glcdc) ?Framebuffer {
        if (!self.domain.powered()) return null;
        if (self.decode(1)) |found| return found;
        return self.decode(2);
    }

    /// Recover one layer's descriptor. Width comes back from the stride and
    /// the format's fetch width, height from LNNUM + 1. A layer that is not
    /// fetching, or whose base is not in RAM, or whose geometry is not sane,
    /// is not a framebuffer and is reported as none rather than as zeroes.
    pub fn decode(self: *const Glcdc, layer: u8) ?Framebuffer {
        const base_off = off.layer_base + off.layer_stride * (@as(u32, layer) - 1);
        if (self.word(base_off + off.flmrd) & field.renb == 0) return null;
        const base = self.word(base_off + off.flm2);
        if (!addressIsRam(base)) return null;
        const stride = self.word(base_off + off.flm3) >> field.stride_shift & field.stride_mask;
        const lines = (self.word(base_off + off.flm5) >> field.lnnum_shift & field.lnnum_mask) + 1;
        const format: Format = @enumFromInt(self.word(base_off + off.flm6) >> field.format_shift & field.format_mask);
        if (stride == 0) return null;
        const width = stride / format.bytesPerPixel();
        if (width == 0 or width > max_dimension or lines > max_dimension) return null;
        return .{
            .base = base,
            .width = width,
            .height = lines,
            .stride = stride,
            .format = format,
            .layer = layer,
            .enabled = self.outputEnabled(),
        };
    }

    /// An unpowered block does not drive the bus: reads give zero, and the
    /// read is counted so the run can say the panel was programmed dark.
    pub fn read(self: *Glcdc, address: u32, width: u3) u32 {
        _ = width;
        if (!self.domain.powered()) {
            self.dark_reads +%= 1;
            return 0;
        }
        return self.word(address - win_base);
    }

    /// A write while the domain is gated reaches no flip-flop on silicon and
    /// is dropped here, counted rather than absorbed. dev snoops the value
    /// into its shadow whatever the domain is doing, so a firmware that
    /// forgot PDCTRGD gets a full framebuffer descriptor there and a dark
    /// panel on the bench.
    pub fn write(self: *Glcdc, address: u32, width: u3, value: u32) void {
        _ = width;
        if (!self.domain.powered()) {
            self.dropped_unpowered +%= 1;
            return;
        }
        const offset = address - win_base;
        if (self.isStart(offset, value)) self.starts +%= 1;
        self.setWord(offset, value);
        self.writes +%= 1;
    }

    /// Whether this write is the edge that starts a layer fetching.
    fn isStart(self: *const Glcdc, offset: u32, value: u32) bool {
        const layer1 = off.layer_base + off.flmrd;
        const layer2 = off.layer_base + off.layer_stride + off.flmrd;
        if (offset != layer1 and offset != layer2) return false;
        return value & field.renb != 0 and self.word(offset) & field.renb == 0;
    }

    /// The window is word-addressed here: the driver programs these
    /// registers a word at a time, and a byte write lands in the word that
    /// holds it rather than being modelled sub-word.
    fn word(self: *const Glcdc, offset: u32) u32 {
        const index = offset / 4;
        if (index >= words) return 0;
        return self.registers[index];
    }

    fn setWord(self: *Glcdc, offset: u32, value: u32) void {
        const index = offset / 4;
        if (index >= words) return;
        self.registers[index] = value;
    }

    pub fn block(self: *Glcdc) periph.Block {
        return .{
            .name = "GLCDC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// Whether an address points into a RAM window a framebuffer can live in.
pub fn addressIsRam(address: u32) bool {
    for (ram_windows) |window| {
        if (address >= window.base and address < window.end) return true;
    }
    return false;
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Glcdc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Glcdc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
