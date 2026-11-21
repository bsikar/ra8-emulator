//! RA4T1 Peripheral Security Control Unit (`PSCU = 0x400E_0000`) and
//! 8-region hardware IDAU attribution (R01UH0999EJ0140 Rev.1.40 §2.4, §40.2–40.4;
//! RA8EMU-A-71).
//!
//! RA4T1 implements 0 SAU regions, so IDAU boundary registers alone decide the
//! Secure / Non-secure callable / Non-secure split across 256 KB code flash,
//! 4 KB data flash, and 40 KB SRAM0. At reset all code flash (`IREGION = 0x07`),
//! data flash (`0x0B`), and SRAM0 (`0x0F`) are Secure, while Type-1 peripherals
//! (`PSARB..PSARE`, `MSSAR`) reset to `0xFFFF_FFFF` (Non-secure).
const chip = @import("../../../root.zig");
const sysc = @import("sysc.zig");

const idau = chip.periph.sau.idau;
const registry = chip.periph.registry;
const sau_attr = chip.periph.sau.attribution;

pub const win_base: u32 = 0x400E_0000;
pub const win_size: u32 = 0x100;

pub const ofs = struct {
    pub const psarb: u32 = 0x04;
    pub const psarc: u32 = 0x08;
    pub const psard: u32 = 0x0C;
    pub const psare: u32 = 0x10;
    pub const mssar: u32 = 0x14;
    pub const cfsamona: u32 = 0x18;
    pub const cfsamonb: u32 = 0x1C;
    pub const dfsamon: u32 = 0x20;
    pub const ssamona: u32 = 0x24;
    pub const ssamonb: u32 = 0x28;
};

pub const iregion = struct {
    pub const code_ns: u8 = 0x05;
    pub const code_nsc: u8 = 0x06;
    pub const code_s: u8 = 0x07;
    pub const data_ns: u8 = 0x09;
    pub const data_s: u8 = 0x0B;
    pub const sram_ns: u8 = 0x0D;
    pub const sram_nsc: u8 = 0x0E;
    pub const sram_s: u8 = 0x0F;
};

pub const range = struct {
    pub const code_base: u32 = 0x0000_0000;
    pub const code_size: u32 = 256 * 1024;
    pub const data_base: u32 = 0x0800_0000;
    pub const data_size: u32 = 4 * 1024;
    pub const sram_base: u32 = 0x2000_0000;
    pub const sram_size: u32 = 40 * 1024;
};

pub const reset_val = struct {
    pub const cfsamona: u32 = 0x00FF_8000;
    pub const cfsamonb: u32 = 0x00FF_FC00;
    pub const dfsamon: u32 = 0x0000_FC00;
    pub const ssamona: u32 = 0x001F_E000;
    pub const ssamonb: u32 = 0x001F_FC00;
};

pub const Pscu = struct {
    psarb: u32 = 0xFFFF_FFFF,
    psarc: u32 = 0xFFFF_FFFF,
    psard: u32 = 0xFFFF_FFFF,
    psare: u32 = 0xFFFF_FFFF,
    mssar: u32 = 0xFFFF_FFFF,
    cfsamona: u32 = reset_val.cfsamona,
    cfsamonb: u32 = reset_val.cfsamonb,
    dfsamon: u32 = reset_val.dfsamon,
    ssamona: u32 = reset_val.ssamona,
    ssamonb: u32 = reset_val.ssamonb,
    ignored_protected: u32 = 0,
    protection: ?*const sysc.Sysc = null,

    pub fn init(protection: ?*const sysc.Sysc) Pscu {
        return .{ .protection = protection };
    }

    pub fn block(self: *Pscu) registry.Block {
        return .{
            .name = "RA4T1 PSCU",
            .base = win_base,
            .size = win_size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .peekFn = readThunk,
        };
    }

    /// Static reset-state IDAU callback for `MemoryMap` descriptors without a live `Board`.
    pub fn resetCallback() idau.Callback {
        return .{ .context = null, .answerFn = answerThunk };
    }

    /// Live IDAU callback reflecting programmed `CFSAMONA/B`, `DFSAMON`, `SSAMONA/B` boundaries.
    pub fn callback(self: *const Pscu) idau.Callback {
        return .{ .context = self, .answerFn = answerThunk };
    }

    fn answerThunk(context: ?*const anyopaque, address: u32) sau_attr.Idau {
        if (context) |ptr| {
            const self: *const Pscu = @ptrCast(@alignCast(ptr));
            return self.idauAt(address);
        }
        const default_pscu: Pscu = .{};
        return default_pscu.idauAt(address);
    }

    /// Hardware IDAU region and security attribution for `address` (HUM Table 2.3, Table 40.1, Table 40.6).
    pub fn idauAt(self: *const Pscu, address: u32) sau_attr.Idau {
        if (address < range.code_size) {
            return classifyTri(address, self.codeSecBytes(), self.codeNscEndBytes(), .{
                .s = iregion.code_s,
                .nsc = iregion.code_nsc,
                .ns = iregion.code_ns,
            });
        }
        if (address >= range.data_base and address - range.data_base < range.data_size) {
            const offset = address - range.data_base;
            if (offset < self.dataSecBytes()) {
                return .{ .state = .secure, .region = iregion.data_s };
            }
            return .{ .state = .non_secure, .region = iregion.data_ns };
        }
        if (address >= range.sram_base and address - range.sram_base < range.sram_size) {
            const offset = address - range.sram_base;
            return classifyTri(offset, self.sramSecBytes(), self.sramNscEndBytes(), .{
                .s = iregion.sram_s,
                .nsc = iregion.sram_nsc,
                .ns = iregion.sram_ns,
            });
        }
        return .{ .state = .non_secure, .exempt = true, .region = null };
    }

    pub fn codeSecBytes(self: *const Pscu) u32 {
        const units = (self.cfsamonb >> 10) & 0x3FFF;
        return @min(range.code_size, units * 1024);
    }

    pub fn codeNscEndBytes(self: *const Pscu) u32 {
        const units = (self.cfsamona >> 15) & 0x1FF;
        return @min(range.code_size, units * 32 * 1024);
    }

    pub fn dataSecBytes(self: *const Pscu) u32 {
        const units = (self.dfsamon >> 10) & 0x3F;
        return @min(range.data_size, units * 1024);
    }

    pub fn sramSecBytes(self: *const Pscu) u32 {
        const units = (self.ssamonb >> 10) & 0x7FF;
        return @min(range.sram_size, units * 1024);
    }

    pub fn sramNscEndBytes(self: *const Pscu) u32 {
        const units = (self.ssamona >> 13) & 0xFF;
        return @min(range.sram_size, units * 8 * 1024);
    }

    fn readThunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Pscu = @ptrCast(@alignCast(ctx));
        return self.read(address, width);
    }

    fn writeThunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Pscu = @ptrCast(@alignCast(ctx));
        self.write(address, width, value);
    }

    pub fn read(self: *const Pscu, address: u32, width: u3) u32 {
        if (address < win_base or address - win_base >= win_size) return 0;
        const offset = address - win_base;
        const aligned = offset & ~@as(u32, 3);
        const word: u32 = switch (aligned) {
            ofs.psarb => self.psarb,
            ofs.psarc => self.psarc,
            ofs.psard => self.psard,
            ofs.psare => self.psare,
            ofs.mssar => self.mssar,
            ofs.cfsamona => self.cfsamona,
            ofs.cfsamonb => self.cfsamonb,
            ofs.dfsamon => self.dfsamon,
            ofs.ssamona => self.ssamona,
            ofs.ssamonb => self.ssamonb,
            else => 0,
        };
        const shift: u5 = @intCast((offset & 3) * 8);
        return maskWidth(word >> shift, width);
    }

    pub fn write(self: *Pscu, address: u32, width: u3, value: u32) void {
        if (address < win_base or address - win_base >= win_size) return;
        if (self.protection) |guard| {
            if (!guard.allows(sysc.prc.security)) {
                self.ignored_protected +%= 1;
                return;
            }
        }
        const offset = address - win_base;
        const aligned = offset & ~@as(u32, 3);
        const target: *u32 = switch (aligned) {
            ofs.psarb => &self.psarb,
            ofs.psarc => &self.psarc,
            ofs.psard => &self.psard,
            ofs.psare => &self.psare,
            ofs.mssar => &self.mssar,
            ofs.cfsamona => &self.cfsamona,
            ofs.cfsamonb => &self.cfsamonb,
            ofs.dfsamon => &self.dfsamon,
            ofs.ssamona => &self.ssamona,
            ofs.ssamonb => &self.ssamonb,
            else => return,
        };
        const merged = mergeSubword(target.*, offset & 3, width, value);
        target.* = sanitizeWord(aligned, merged);
    }
};

const TriIds = struct { s: u8, nsc: u8, ns: u8 };

fn classifyTri(offset: u32, sec_end: u32, nsc_end: u32, ids: TriIds) sau_attr.Idau {
    if (offset < sec_end) return .{ .state = .secure, .region = ids.s };
    if (offset < nsc_end) return .{ .state = .callable, .region = ids.nsc };
    return .{ .state = .non_secure, .region = ids.ns };
}

fn sanitizeWord(aligned: u32, raw: u32) u32 {
    return switch (aligned) {
        ofs.psarb => raw | ~@as(u32, 0x804C_0010),
        ofs.psarc => raw | ~@as(u32, 0x1810_2003),
        ofs.psard => raw | ~@as(u32, 0x1C51_780C),
        ofs.psare => raw | ~@as(u32, 0xFC00_0007),
        ofs.mssar => raw | ~@as(u32, 0x0000_0003),
        ofs.cfsamona => raw & reset_val.cfsamona,
        ofs.cfsamonb => raw & reset_val.cfsamonb,
        ofs.dfsamon => raw & reset_val.dfsamon,
        ofs.ssamona => raw & reset_val.ssamona,
        ofs.ssamonb => raw & reset_val.ssamonb,
        else => raw,
    };
}

fn maskWidth(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}

fn mergeSubword(current: u32, byte_off: u32, width: u3, value: u32) u32 {
    const shift: u5 = @intCast(byte_off * 8);
    const width_mask: u32 = switch (width) {
        1 => 0xFF,
        2 => 0xFFFF,
        else => return value,
    };
    const shifted_mask = width_mask << shift;
    return (current & ~shifted_mask) | ((value & width_mask) << shift);
}
