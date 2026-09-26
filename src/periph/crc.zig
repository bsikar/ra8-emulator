//! CRC: the calculator the firmware's own checksum has to agree with.
//!
//! The RA8D2 CRC unit lives at 0x4031_0000 (HUM Ch 48, ra8_crc_regs.h) and is
//! one running remainder fed a byte at a time. Until now it fell through to the
//! sparse register file, and a sparse cell cannot be a CRC: `crc_demo` in the C
//! tree printed `hw=00000000 ... match=N`, because a read of CRCDOR returned a
//! constant instead of the fold of everything written to CRCDIR. A checksum
//! that disagrees with its own software reference is worse than no checksum, so
//! this models the unit exactly, ported from board_periph_crc.c on dev.
//!
//!   CRCCR0 (+0x00, 8b)  GPS[2:0] polynomial select, LMS bit order, DORCLR
//!   CRCCR1 (+0x01, 8b)  snoop control, shadowed only
//!   CRCDIR (+0x04)      write-only data in: every byte of the access is folded
//!   CRCDOR (+0x08, 32b) the running remainder, readable and seedable
//!
//! Bit order follows the RA8D2 polynomial definitions rather than a flag: the
//! CRC-32, CRC-32C and CRC-16 modes fold LSB-first, CRC-8 and CRC-CCITT fold
//! MSB-first. The unit applies no seed and no final XOR, so a driver doing
//! CRC-32 pre-seeds CRCDOR with 0xFFFF_FFFF and inverts the readback itself;
//! that is why CRCDOR is writable here.
//!
//! The width of the access is the feed width, which is the one thing a byte
//! model has to get right: a 32-bit store to CRCDIR folds four bytes LSB-first,
//! the order ra8_crc's word packing produces, and an 8-bit store folds one.
const std = @import("std");
const periph = @import("registry.zig");

/// CRC geometry (HUM Ch 48). The Non-secure alias is folded onto this base by
/// the bus before anything here sees it.
pub const win_base: u32 = 0x4031_0000;
pub const win_span: u32 = 0x20;

pub const off_cr0: u32 = 0x00;
pub const off_cr1: u32 = 0x01;
pub const off_dir: u32 = 0x04;
pub const off_dor: u32 = 0x08;

const gps_mask: u8 = 0x07;
pub const dorclr: u8 = 0x80;

/// CRCCR0.GPS encodings.
pub const Gps = enum(u8) {
    none = 0,
    crc8 = 1,
    crc16 = 2,
    ccitt = 3,
    crc32 = 4,
    crc32c = 5,
    _,
};

/// Reflected (LSB-first) polynomials.
const poly_16_refl: u32 = 0x0000_A001;
const poly_32_refl: u32 = 0xEDB8_8320;
const poly_32c_refl: u32 = 0x82F6_3B78;
/// MSB-first polynomials.
const poly_8_fwd: u32 = 0x0000_0007;
const poly_ccitt_fwd: u32 = 0x0000_1021;

/// Fold one byte into a reflected CRC of any width.
fn stepReflected(crc: u32, byte: u8, poly: u32) u32 {
    var value = crc ^ byte;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        value = if (value & 1 != 0) (value >> 1) ^ poly else value >> 1;
    }
    return value;
}

/// Fold one byte into an MSB-first CRC of `width` bits.
fn stepForward(crc: u32, byte: u8, poly: u32, width: u5) u32 {
    const top: u32 = @as(u32, 1) << (width - 1);
    const keep: u32 = if (width >= 32) 0xFFFF_FFFF else (@as(u32, 1) << width) - 1;
    var value = crc ^ (@as(u32, byte) << (width - 8));
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const carry = value & top != 0;
        value = (value << 1) & keep;
        if (carry) value ^= poly;
    }
    return value & keep;
}

/// The CRC unit: three registers and a byte counter, which is all of it.
pub const Crc = struct {
    cr0: u8 = 0,
    cr1: u8 = 0,
    dor: u32 = 0,
    bytes: u32 = 0,

    pub fn init() Crc {
        return .{};
    }

    pub fn gps(self: *const Crc) Gps {
        return @enumFromInt(self.cr0 & gps_mask);
    }

    /// Untouched units stay out of the end-of-run report.
    pub fn quiet(self: *const Crc) bool {
        return self.bytes == 0;
    }

    /// Fold one byte with whatever polynomial CRCCR0.GPS currently selects.
    /// GPS=0 selects nothing, and the hardware calculates nothing; the byte is
    /// still counted, because the firmware still fed it.
    pub fn feed(self: *Crc, byte: u8) void {
        self.dor = switch (self.gps()) {
            .crc8 => stepForward(self.dor, byte, poly_8_fwd, 8),
            .crc16 => stepReflected(self.dor, byte, poly_16_refl),
            .ccitt => stepForward(self.dor, byte, poly_ccitt_fwd, 16),
            .crc32 => stepReflected(self.dor, byte, poly_32_refl),
            .crc32c => stepReflected(self.dor, byte, poly_32c_refl),
            else => self.dor,
        };
        self.bytes +%= 1;
    }

    pub fn read(self: *Crc, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset == off_cr0) return self.cr0;
        if (offset == off_cr1) return self.cr1;
        if (offset >= off_dor and offset < off_dor + 4) {
            // CRCDOR and its 16- and 8-bit aliases share +0x08: serve the byte
            // the access starts at, so a halfword read of +0x0A is the top half.
            const shift: u5 = @intCast((offset - off_dor) * 8);
            return trim(self.dor >> shift, width);
        }
        // CRCDIR is write-only, and nothing else in the window exists. Zero is
        // what silicon returns, and it beats the sparse file's alternating
        // stand-in: a driver polling here is reading a register that has no
        // value to give.
        return 0;
    }

    pub fn write(self: *Crc, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset == off_cr0) {
            self.cr0 = @truncate(value);
            if (self.cr0 & dorclr != 0) self.dor = 0;
            return;
        }
        if (offset == off_cr1) {
            self.cr1 = @truncate(value);
            return;
        }
        if (offset == off_dir) {
            var i: u3 = 0;
            while (i < width) : (i += 1) {
                const shift: u5 = @as(u5, i) * 8;
                self.feed(@truncate(value >> shift));
            }
            return;
        }
        if (offset >= off_dor and offset < off_dor + 4) {
            const shift: u5 = @intCast((offset - off_dor) * 8);
            if (width >= 4) {
                self.dor = value;
                return;
            }
            const window = trim(0xFFFF_FFFF, width) << shift;
            self.dor = (self.dor & ~window) | ((value << shift) & window);
        }
    }

    pub fn block(self: *Crc) periph.Block {
        return .{
            .name = "CRC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn trim(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Crc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Crc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one CRC register, so a test or a later slice does not have
/// to do the arithmetic itself.
pub fn regAddress(offset: u32) u32 {
    return win_base + offset;
}

pub const reg_cr0 = off_cr0;
pub const reg_cr1 = off_cr1;
pub const reg_dir = off_dir;
pub const reg_dor = off_dor;
