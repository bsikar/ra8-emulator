//! The DRW texture source: where a textured blit gets its colour from.
//!
//! drw.zig scans a bounding box and limit.zig decides which pixels of it
//! are painted; this decides what colour each painted pixel starts as. With
//! CONTROL2.TEXTUREENABLE clear that is COLOR1 and nothing here runs. With
//! it set the engine walks a second pair of linear forms over the same box,
//! U and V, and reads a texel out of memory at TEXORIGIN.
//!
//! dev models none of it: board_periph_drw.c accepts the texture registers
//! and discards them (its line 641), then declines every render with a
//! source enabled, so a textured blit came back to a blank framebuffer and
//! the app passed. Every UI image, font glyph and icon on this part is a
//! textured blit, so that was most of the picture.
//!
//! Two coordinate generators, not one, because the hardware has two:
//!
//!   * U is plain sub-pixel, LUSTART + x*LUXADD + y*LUYADD in sixteenths
//!     (ra8_drw_regs.h `k_ra8_drw_subpixel_unit`), the same fixed point the
//!     six edge limiters use.
//!   * V arrives already scaled by TEXPITCH: the engine programs
//!     LVSTARTI = floor(Vs) * TEXPITCH, LVSTARTF = (Vs - floor(Vs)) *
//!     TEXPITCH, and the increments the same way, so the address adder adds
//!     U straight on and the second multiplier the row-unit model needed
//!     never exists (HUM Ch 62.6.3.2 p 3731). LVSTARTF and both halves of
//!     LVYXADDF are 16-bit fields holding those scaled texel counts, which
//!     is why they are plain integers here rather than a sub-texel fixed
//!     point: a Q0.16 field cannot even hold one scaled row. The HUM fixes
//!     which half of LVYXADDF is which too (Ch 62.2.24 p 3703: LVXADDF low,
//!     LVYADDF high), and marks LVSTARTF[31:16] as write-zero (Ch 62.2.21
//!     p 3702).
const std = @import("std");

const clut = @import("clut.zig");
const Guest = @import("../../core/cpu/memory/guest/guest.zig").Guest;
const memmap = @import("../../core/memmap.zig");
const texel = @import("texel.zig");

/// Register byte offsets (ra8_drw_regs.h, HUM Ch 62.2.13-62.2.32).
pub const off = struct {
    pub const lustart: u32 = 0x090;
    pub const luxadd: u32 = 0x094;
    pub const luyadd: u32 = 0x098;
    pub const lvstarti: u32 = 0x09C;
    pub const lvstartf: u32 = 0x0A0;
    pub const lvxaddi: u32 = 0x0A4;
    pub const lvyaddi: u32 = 0x0A8;
    pub const lvyxaddf: u32 = 0x0AC;
    pub const texpitch: u32 = 0x0B4;
    pub const texmask: u32 = 0x0B8;
    pub const texorigin: u32 = 0x0BC;
    pub const texcladdr: u32 = 0x0DC;
    pub const texcldata: u32 = 0x0E0;
    pub const texcloffset: u32 = 0x0E4;
    pub const colkey: u32 = 0x0E8;
};

/// CONTROL2 bits this file owns (HUM Ch 62.2.2 p 3690).
pub const control2 = struct {
    pub const clamp_x: u32 = 1 << 14;
    pub const clamp_y: u32 = 1 << 15;
    pub const filter_x: u32 = 1 << 16;
    pub const filter_y: u32 = 1 << 17;
    pub const rle_enable: u32 = 1 << 24;
    pub const clut_enable: u32 = 1 << 25;
    pub const colkey_enable: u32 = 1 << 26;
    pub const clut_565: u32 = 1 << 27;
};

/// The fixed point the coordinates arrive in, and the clamps the HUM puts
/// on the texture geometry registers (ra8_drw_regs.h pp 642-644, 690-691).
pub const limits = struct {
    pub const subpixel_shift: u5 = 4;
    pub const texpitch_max: u32 = 2048;
    /// TEXUMASK[10:0] and TEXVMASK[31:11], the fields the HUM puts TEXMASK
    /// in (Ch 62.2.16 p 3700). The texture width and height maximums sit
    /// behind those fields and are the programmer's to respect; the hardware
    /// only masks with what it was given.
    pub const umask_field: u32 = 0x7FF;
    pub const vmask_shift: u5 = 11;
    pub const vmask_field: u32 = 0x1F_FFFF;
    /// The fraction fields of LVSTARTF and LVYXADDF: 16 bits each, holding
    /// TEXPITCH-scaled texel counts (HUM Ch 62.2.21 p 3702, 62.2.24 p 3703).
    pub const fraction_field: u32 = 0xFFFF;
    pub const fraction_half_shift: u5 = 16;
    /// RGB of an ARGB8888 word, which is what the colour key compares.
    pub const rgb_mask: u32 = 0x00FF_FFFF;
};

/// Why a textured render cannot be sampled, as against merely producing no
/// pixel at one coordinate.
pub const Refusal = enum {
    /// A READFORMAT code with no documented width.
    format,
    /// An indexed format with CONTROL2.CLUTENABLE clear: the texel is an
    /// index into a palette the engine was told not to read.
    no_clut,
    /// Bilinear filtering, which weights four texels by the sub-texel
    /// fraction. Not modelled: nearest here would be a different picture.
    filtered,
    /// An RLE-compressed source, a second decoder entirely.
    rle,
    /// TEXORIGIN or TEXPITCH never programmed, or TEXPITCH past the
    /// documented 2048 clamp.
    geometry,
};

/// One texture coordinate pair for one pixel of the bounding box.
pub const Coord = struct {
    u: i64,
    v: i64,
};

/// The texture source: the registers, the palette, and the counters behind
/// the end-of-run line.
pub const Source = struct {
    lustart: i32 = 0,
    luxadd: i32 = 0,
    luyadd: i32 = 0,
    lvstarti: i32 = 0,
    lvstartf: u32 = 0,
    lvxaddi: i32 = 0,
    lvyaddi: i32 = 0,
    lvyxaddf: u32 = 0,
    texpitch: u32 = 0,
    texmask: u32 = 0,
    texorigin: u32 = 0,
    colkey: u32 = 0,

    palette: clut.Clut = .{},

    /// Texels sampled, and the ones that produced no pixel.
    texels: u64 = 0,
    keyed: u64 = 0,
    /// Coordinates that fell outside the texture and were wrapped or
    /// clamped back into it.
    wrapped: u64 = 0,
    /// Texel reads that went nowhere mapped, and ones aimed outside RAM.
    faults: u64 = 0,
    off_ram: u64 = 0,

    /// Take a texture register write, or report that the offset is not one.
    pub fn latch(self: *Source, offset: u32, value: u32) bool {
        const signed: i32 = @bitCast(value);
        switch (offset) {
            off.lustart => self.lustart = signed,
            off.luxadd => self.luxadd = signed,
            off.luyadd => self.luyadd = signed,
            off.lvstarti => self.lvstarti = signed,
            off.lvstartf => self.lvstartf = value,
            off.lvxaddi => self.lvxaddi = signed,
            off.lvyaddi => self.lvyaddi = signed,
            off.lvyxaddf => self.lvyxaddf = value,
            off.texpitch => self.texpitch = value,
            off.texmask => self.texmask = value,
            off.texorigin => self.texorigin = value,
            off.texcladdr => self.palette.setAddress(value),
            off.texcldata => self.palette.push(value),
            off.texcloffset => self.palette.setOffset(value),
            off.colkey => self.colkey = value,
            else => return false,
        }
        return true;
    }

    /// What the source holds for a register, so a narrow store keeps the
    /// lanes it does not name. Null when the offset is not a texture
    /// register; TEXCLDATA is consumed by its write and holds nothing, so it
    /// answers zero rather than a palette entry.
    pub fn held(self: *const Source, offset: u32) ?u32 {
        return switch (offset) {
            off.lustart => @bitCast(self.lustart),
            off.luxadd => @bitCast(self.luxadd),
            off.luyadd => @bitCast(self.luyadd),
            off.lvstarti => @bitCast(self.lvstarti),
            off.lvstartf => self.lvstartf,
            off.lvxaddi => @bitCast(self.lvxaddi),
            off.lvyaddi => @bitCast(self.lvyaddi),
            off.lvyxaddf => self.lvyxaddf,
            off.texpitch => self.texpitch,
            off.texmask => self.texmask,
            off.texorigin => self.texorigin,
            off.texcladdr => self.palette.cursor,
            off.texcldata => 0,
            off.texcloffset => self.palette.offset,
            off.colkey => self.colkey,
            else => null,
        };
    }

    /// Why this texture configuration cannot be sampled, or null when it can.
    pub fn refusal(self: *const Source, control2_word: u32) ?Refusal {
        if (control2_word & control2.rle_enable != 0) return .rle;
        if (control2_word & (control2.filter_x | control2.filter_y) != 0) return .filtered;
        const format = texel.Format.decode(control2_word);
        if (format.bits() == null) return .format;
        if (format.indexed() and control2_word & control2.clut_enable == 0) return .no_clut;
        if (self.texorigin == 0 or self.texpitch == 0) return .geometry;
        if (self.texpitch > limits.texpitch_max) return .geometry;
        return null;
    }

    /// The raw U and V for one pixel of the bounding box, before the mask.
    /// U comes out in texels; V comes out already TEXPITCH-scaled, the
    /// linear texel index the address adder consumes (HUM Ch 62.6.3.2
    /// p 3731), with the fraction fields added in as the scaled counts they
    /// hold rather than shifted as a sub-texel fixed point.
    pub fn coordinate(self: *const Source, column: u32, row: u32) Coord {
        const x: i64 = column;
        const y: i64 = row;
        const u_sub = @as(i64, self.lustart) + x * self.luxadd + y * self.luyadd;
        const scaled = @as(i64, self.lvstarti) + x * self.lvxaddi + y * self.lvyaddi;
        const fraction = @as(i64, self.lvstartf & limits.fraction_field) +
            x * (self.lvyxaddf & limits.fraction_field) +
            y * (self.lvyxaddf >> limits.fraction_half_shift);
        return .{
            .u = u_sub >> limits.subpixel_shift,
            .v = scaled + fraction,
        };
    }

    /// TEXMASK's two fields, decoded where the HUM puts them (Ch 62.2.16
    /// p 3700): TEXUMASK[10:0] on the U side, TEXVMASK[31:11] on the V
    /// side, the V one carrying TEXPITCH * (height - 1) rather than a row
    /// count.
    pub fn masks(self: *const Source) struct { u: u32, v: u32 } {
        return .{
            .u = self.texmask & limits.umask_field,
            .v = self.texmask >> limits.vmask_shift & limits.vmask_field,
        };
    }

    /// The colour one pixel of the bounding box starts as, or null when the
    /// texture says not to paint it at all.
    pub fn sample(self: *Source, memory: Guest, control2_word: u32, column: u32, row: u32) ?u32 {
        const format = texel.Format.decode(control2_word);
        const width = format.bits() orelse return null;
        const raw = self.fetch(memory, format, width, control2_word, column, row) orelse return null;
        self.texels +%= 1;
        const shade = self.colour(format, control2_word, raw);
        if (control2_word & control2.colkey_enable != 0 and
            shade & limits.rgb_mask == self.colkey & limits.rgb_mask)
        {
            self.keyed +%= 1;
            return null;
        }
        return shade;
    }

    /// A raw texel out of memory, with the coordinate folded into the
    /// texture first.
    fn fetch(
        self: *Source,
        memory: Guest,
        format: texel.Format,
        width: u32,
        control2_word: u32,
        column: u32,
        row: u32,
    ) ?u32 {
        _ = format;
        const raw_coord = self.coordinate(column, row);
        const bound = self.masks();
        const u = self.fold(raw_coord.u, bound.u, control2_word & control2.clamp_x != 0);
        const v = self.fold(raw_coord.v, bound.v, control2_word & control2.clamp_y != 0);
        // V lands here already TEXPITCH-scaled and U adds straight on; the
        // second multiply a row-unit V needed is the one the HUM's
        // pre-scaling saves (Ch 62.6.3.2 p 3731).
        const at = (@as(u64, v) + u) * width;
        const byte = @as(u64, self.texorigin) + at / 8;
        if (byte > std.math.maxInt(u32) - 4) {
            self.faults +%= 1;
            return null;
        }
        const address: u32 = @intCast(byte);
        // A texture lives in memory the engine can reach, not in the
        // peripheral window and not in the core's own TCM: dev never read one
        // at all, so this is the first chance to say where it is.
        if (!memmap.initiatorHolds(address, 4)) {
            self.off_ram +%= 1;
            return null;
        }
        var window = @as([4]u8, @splat(0));
        memory.read(address, window[0..]) catch {
            self.faults +%= 1;
            return null;
        };
        return texel.extract(width, @intCast(at % 8), window);
    }

    /// One coordinate inside the texture: clamped to the mask, or wrapped
    /// around it, counting either way because a blit that leaves its own
    /// texture is usually a UV programming bug.
    fn fold(self: *Source, value: i64, mask: u32, clamped: bool) u32 {
        if (value >= 0 and value <= mask) return @intCast(value);
        self.wrapped +%= 1;
        if (clamped) return if (value < 0) 0 else mask;
        if (mask == 0) return 0;
        // The register is a mask and the HUM's wrap is that mask applied
        // (Ch 62.2.16 p 3700): a whole TEXPITCH past the last row lands back
        // on row zero because the row bits wrap under it, and a negative
        // coordinate rides the same two's-complement wrap onto the far edge.
        // For the U mask, width - 1, that is the wrap-around modulo the HUM
        // allows any power-of-two width for (Ch 62.2.16 p 3700).
        return @intCast(@as(u64, @bitCast(value)) & @as(u64, mask));
    }

    /// A raw texel as an ARGB8888 colour, through the palette when the
    /// format is an indexed one.
    fn colour(self: *const Source, format: texel.Format, control2_word: u32, raw: u32) u32 {
        if (!format.indexed()) return format.expand(raw);
        const entry = self.palette.lookup(format.index(raw), control2_word & control2.clut_565 != 0);
        const carried = format.carriedAlpha(raw) orelse return entry;
        return entry & limits.rgb_mask | carried << 24;
    }

    pub fn quiet(self: *const Source) bool {
        return self.texels == 0 and self.wrapped == 0 and self.faults == 0 and self.off_ram == 0;
    }
};
