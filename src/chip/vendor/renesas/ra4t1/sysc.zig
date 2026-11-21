//! RA4T1 System Control, Clock Generation, and Register Write Protection
//! (R01UH0999EJ0140 Rev.1.40 Ch. 8, Ch. 10, Ch. 11; RA8EMU-A-71).
//!
//! SYSC lives at `0x4001_E000` (distinct from RA8: `PRCR` sits at `0x4001_E3FE`,
//! `PRCRN` at `0x4001_E3FA`, `SCKDIVCR` resets to `0x2200_2222` `/4`, `SCKSCR`
//! resets to `0x01` MOCO 8 MHz, and `HOCOCR2` resets to `0x03` prohibited until
//! written while `HOCOCR.HCSTP == 1`).
const chip = @import("../../../root.zig");

const registry = chip.periph.registry;

pub const win_base: u32 = 0x4001_E000;
pub const win_size: u32 = 0x500;

pub const ofs = struct {
    pub const sbycr: u32 = 0x00C;
    pub const sckdivcr: u32 = 0x020;
    pub const sckscr: u32 = 0x026;
    pub const pllccr: u32 = 0x028;
    pub const pllcr: u32 = 0x02A;
    pub const mosccr: u32 = 0x032;
    pub const hococr: u32 = 0x036;
    pub const hococr2: u32 = 0x037;
    pub const mococr: u32 = 0x038;
    pub const oscsf: u32 = 0x03C;
    pub const ckocr: u32 = 0x03E;
    pub const rstsr1: u32 = 0x0C0;
    pub const momcr: u32 = 0x413;
    pub const prcrn: u32 = 0x3FA;
    pub const prcr: u32 = 0x3FE;
    pub const rstsr0: u32 = 0x410;
    pub const rstsr2: u32 = 0x411;
    pub const sosccr: u32 = 0x480;
    pub const somcr: u32 = 0x481;
    pub const lococr: u32 = 0x490;
    pub const mocoutcr: u32 = 0x061;
    pub const hocoutcr: u32 = 0x062;
    pub const locoutcr: u32 = 0x492;
};

pub const prcr_key: u16 = 0xA500;
pub const prcr_mask: u16 = 0x001B; // PRC0 | PRC1 | PRC3 | PRC4
pub const prcrn_mask: u16 = 0x000B; // PRC0 | PRC1 | PRC3

pub const prc = struct {
    pub const clock: u16 = 1 << 0; // PRC0
    pub const low_power: u16 = 1 << 1; // PRC1
    pub const lvd: u16 = 1 << 3; // PRC3
    pub const security: u16 = 1 << 4; // PRC4
};

pub const cksel = struct {
    pub const hoco: u8 = 0;
    pub const moco: u8 = 1;
    pub const loco: u8 = 2;
    pub const mosc: u8 = 3;
    pub const sosc: u8 = 4;
    pub const pll: u8 = 5;
};

pub const oscsf_bit = struct {
    pub const hoco: u8 = 1 << 0;
    pub const mosc: u8 = 1 << 3;
    pub const pll: u8 = 1 << 5;
};

pub const Sysc = struct {
    sckdivcr: u32 = 0x2200_2222,
    sckscr: u8 = cksel.moco,
    pllccr: u16 = 0x1300,
    pllcr: u8 = 0x01,
    mosccr: u8 = 0x01,
    hococr: u8 = 0x01,
    hococr2: u8 = 0x03,
    mococr: u8 = 0x00,
    ckocr: u8 = 0x00,
    sbycr: u16 = 0x0000,
    prcr: u16 = 0x0000,
    momcr: u8 = 0x00,
    sosccr: u8 = 0x00,
    somcr: u8 = 0x00,
    lococr: u8 = 0x00,
    rstsr0: u8 = 0x01,
    rstsr1: u16 = 0x0000,
    rstsr2: u8 = 0x00,
    ignored_protected: u32 = 0,
    bad_keys: u32 = 0,

    pub fn init() Sysc {
        return .{};
    }

    pub fn block(self: *Sysc) registry.Block {
        return .{
            .name = "RA4T1 SYSC",
            .base = win_base,
            .size = win_size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .peekFn = readThunk,
        };
    }

    pub fn allows(self: *const Sysc, mask: u16) bool {
        return (self.prcr & mask) != 0;
    }

    /// OSCSF read-only stabilization status derived live from oscillator control bits.
    pub fn oscsf(self: *const Sysc) u8 {
        var bits: u8 = 0;
        if ((self.hococr & 0x01) == 0 and (self.hococr2 & 0x03) != 0x03) {
            bits |= oscsf_bit.hoco;
        }
        if ((self.mosccr & 0x01) == 0) {
            bits |= oscsf_bit.mosc;
        }
        if ((self.pllcr & 0x01) == 0) {
            bits |= oscsf_bit.pll;
        }
        return bits;
    }

    /// Current system clock source frequency in Hz (`ICLK` before `SCKDIVCR` division).
    pub fn sourceHz(self: *const Sysc) u32 {
        return switch (self.sckscr & 0x07) {
            cksel.hoco => switch (self.hococr2 & 0x03) {
                0 => 16_000_000,
                1 => 18_000_000,
                2 => 20_000_000,
                else => 0,
            },
            cksel.moco => 8_000_000,
            cksel.loco, cksel.sosc => 32_768,
            cksel.mosc => 24_000_000,
            cksel.pll => self.pllHz(),
            else => 8_000_000,
        };
    }

    fn pllHz(self: *const Sysc) u32 {
        const src: u64 = if ((self.pllccr & (1 << 4)) != 0) self.hocoHz() else 24_000_000;
        const div: u64 = @as(u64, (self.pllccr & 0x03)) + 1;
        const raw_mul: u64 = ((self.pllccr >> 8) & 0x3F) + 1;
        const freq = (src * raw_mul) / (2 * div);
        return @intCast(@min(freq, 100_000_000));
    }

    fn hocoHz(self: *const Sysc) u64 {
        return switch (self.hococr2 & 0x03) {
            0 => 16_000_000,
            1 => 18_000_000,
            else => 20_000_000,
        };
    }

    /// Divide ratio encoded in `SCKDIVCR` at shift `bit_shift` (`ICK=24`, `PCKA=12`, `PCKB=8`, `PCKD=0`).
    pub fn dividerFor(self: *const Sysc, bit_shift: u5) u32 {
        const code: u3 = @truncate(self.sckdivcr >> bit_shift);
        if (code > 6) return 1;
        return @as(u32, 1) << code;
    }

    pub fn iclkHz(self: *const Sysc) u32 {
        return @max(@as(u32, 1), self.sourceHz() / self.dividerFor(24));
    }

    pub fn pclkdHz(self: *const Sysc) u32 {
        return @max(@as(u32, 1), self.sourceHz() / self.dividerFor(0));
    }

    pub fn pclkbHz(self: *const Sysc) u32 {
        return @max(@as(u32, 1), self.sourceHz() / self.dividerFor(8));
    }

    fn readThunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Sysc = @ptrCast(@alignCast(ctx));
        return self.read(address, width);
    }

    fn writeThunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Sysc = @ptrCast(@alignCast(ctx));
        self.write(address, width, value);
    }

    pub fn read(self: *const Sysc, address: u32, width: u3) u32 {
        if (address < win_base or address - win_base >= win_size) return 0;
        const offset = address - win_base;
        var out: u32 = 0;
        const count: usize = switch (width) {
            1 => 1,
            2 => 2,
            else => 4,
        };
        for (0..count) |i| {
            const b = self.readByte(offset + @as(u32, @intCast(i)));
            out |= @as(u32, b) << @intCast(i * 8);
        }
        return out;
    }

    fn readByte(self: *const Sysc, offset: u32) u8 {
        return switch (offset) {
            ofs.sbycr => @truncate(self.sbycr),
            ofs.sbycr + 1 => @truncate(self.sbycr >> 8),
            ofs.sckdivcr...ofs.sckdivcr + 3 => byteOf(self.sckdivcr, offset - ofs.sckdivcr),
            ofs.sckscr => self.sckscr,
            ofs.pllccr => @truncate(self.pllccr),
            ofs.pllccr + 1 => @truncate(self.pllccr >> 8),
            ofs.pllcr => self.pllcr,
            ofs.mosccr => self.mosccr,
            ofs.hococr => self.hococr,
            ofs.hococr2 => self.hococr2,
            ofs.mococr => self.mococr,
            ofs.oscsf => self.oscsf(),
            ofs.ckocr => self.ckocr,
            ofs.rstsr1 => @truncate(self.rstsr1),
            ofs.rstsr1 + 1 => @truncate(self.rstsr1 >> 8),
            ofs.prcrn => @truncate(self.prcr & prcrn_mask),
            ofs.prcrn + 1 => 0,
            ofs.prcr => @truncate(self.prcr & prcr_mask),
            ofs.prcr + 1 => 0,
            ofs.rstsr0 => self.rstsr0,
            ofs.rstsr2 => self.rstsr2,
            ofs.momcr => self.momcr,
            ofs.sosccr => self.sosccr,
            ofs.somcr => self.somcr,
            ofs.lococr => self.lococr,
            else => 0,
        };
    }

    pub fn write(self: *Sysc, address: u32, width: u3, value: u32) void {
        if (address < win_base or address - win_base >= win_size) return;
        const offset = address - win_base;
        if (self.writeSpecial(offset, width, value)) return;
        const count: usize = if (width == 1) 1 else if (width == 2) 2 else 4;
        for (0..count) |i| {
            const b: u8 = @truncate(value >> @intCast(i * 8));
            self.writeByte(offset + @as(u32, @intCast(i)), b);
        }
    }

    fn writeSpecial(self: *Sysc, offset: u32, width: u3, value: u32) bool {
        if (width == 2 and (offset == ofs.prcr or offset == ofs.prcrn)) {
            self.writePrcr(offset == ofs.prcrn, @truncate(value));
            return true;
        }
        if (width == 4 and offset == ofs.sckdivcr) {
            self.writeCgcWord(&self.sckdivcr, value & 0x7700_7777);
            return true;
        }
        if (width == 2 and offset == ofs.pllccr) {
            self.writeProtected16(&self.pllccr, prc.clock, @truncate(value));
            return true;
        }
        if (width == 2 and offset == ofs.sbycr) {
            self.writeProtected16(&self.sbycr, prc.low_power, @truncate(value));
            return true;
        }
        return false;
    }

    fn writeProtected16(self: *Sysc, target: *u16, gate: u16, value: u16) void {
        if (!self.allows(gate)) {
            self.ignored_protected +%= 1;
            return;
        }
        target.* = value;
    }

    fn writePrcr(self: *Sysc, non_secure_view: bool, value: u16) void {
        if ((value & 0xFF00) != prcr_key) {
            self.bad_keys +%= 1;
            return;
        }
        if (non_secure_view) {
            const keep_prc4 = self.prcr & prc.security;
            self.prcr = (value & prcrn_mask) | keep_prc4;
            return;
        }
        self.prcr = value & prcr_mask;
    }

    fn writeCgcWord(self: *Sysc, target: *u32, value: u32) void {
        if (!self.allows(prc.clock)) {
            self.ignored_protected +%= 1;
            return;
        }
        target.* = value;
    }

    fn writeByte(self: *Sysc, offset: u32, byte: u8) void {
        if (offset >= ofs.sckdivcr and offset < ofs.sckdivcr + 4) {
            if (!self.allows(prc.clock)) {
                self.ignored_protected +%= 1;
                return;
            }
            const shift: u5 = @intCast((offset - ofs.sckdivcr) * 8);
            const mask_32: u32 = @as(u32, 0xFF) << shift;
            self.sckdivcr = (self.sckdivcr & ~mask_32) | (@as(u32, byte & 0x77) << shift);
            return;
        }
        switch (offset) {
            ofs.sckscr => self.writeSckscr(byte),
            ofs.pllcr => self.writeCgcByte(&self.pllcr, byte & 0x01),
            ofs.mosccr => self.writeCgcByte(&self.mosccr, byte & 0x01),
            ofs.hococr => self.writeCgcByte(&self.hococr, byte & 0x01),
            ofs.hococr2 => self.writeHococr2(byte),
            ofs.mococr => self.writeCgcByte(&self.mococr, byte & 0x01),
            ofs.ckocr => self.writeCgcByte(&self.ckocr, byte & 0x8F),
            ofs.momcr => self.writeCgcByte(&self.momcr, byte),
            ofs.sosccr => self.writeCgcByte(&self.sosccr, byte & 0x01),
            ofs.somcr => self.writeCgcByte(&self.somcr, byte),
            ofs.lococr => self.writeCgcByte(&self.lococr, byte & 0x01),
            ofs.sbycr => self.writeLpmByte(&self.sbycr, byte, 0),
            ofs.sbycr + 1 => self.writeLpmByte(&self.sbycr, byte, 8),
            else => {},
        }
    }

    fn writeSckscr(self: *Sysc, byte: u8) void {
        if (!self.allows(prc.clock)) {
            self.ignored_protected +%= 1;
            return;
        }
        const next = byte & 0x07;
        if (self.sourceReady(next)) self.sckscr = next;
    }

    fn sourceReady(self: *const Sysc, source: u8) bool {
        return switch (source) {
            cksel.hoco => (self.oscsf() & oscsf_bit.hoco) != 0,
            cksel.moco => (self.mococr & 0x01) == 0,
            cksel.loco => (self.lococr & 0x01) == 0,
            cksel.mosc => (self.oscsf() & oscsf_bit.mosc) != 0,
            cksel.sosc => (self.sosccr & 0x01) == 0,
            cksel.pll => (self.oscsf() & oscsf_bit.pll) != 0,
            else => false,
        };
    }

    fn writeCgcByte(self: *Sysc, target: *u8, byte: u8) void {
        if (!self.allows(prc.clock)) {
            self.ignored_protected +%= 1;
            return;
        }
        target.* = byte;
    }

    fn writeHococr2(self: *Sysc, byte: u8) void {
        if (!self.allows(prc.clock)) {
            self.ignored_protected +%= 1;
            return;
        }
        // HUM §8.2.10: HOCOCR2 must only change while HOCO is stopped.
        if ((self.hococr & 0x01) == 0) return;
        self.hococr2 = byte & 0x03;
    }

    fn writeLpmByte(self: *Sysc, target: *u16, byte: u8, shift: u4) void {
        if (!self.allows(prc.low_power)) {
            self.ignored_protected +%= 1;
            return;
        }
        const mask_16: u16 = @as(u16, 0xFF) << shift;
        target.* = (target.* & ~mask_16) | (@as(u16, byte) << shift);
    }
};

fn byteOf(word: u32, index: u32) u8 {
    return @truncate(word >> @intCast(index * 8));
}
