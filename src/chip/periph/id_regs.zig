//! Armv8-M / Armv8.1-M architectural identification and media/FP feature
//! registers (DDI0553B.y D1.2, Cortex-M55 TRM 101051_0101_02_en Tables 5-1..5-3).
const std = @import("std");

pub const addr = struct {
    pub const revidr: u32 = 0xE000_ECFC;
    pub const id_pfr0: u32 = 0xE000_ED40;
    pub const id_pfr1: u32 = 0xE000_ED44;
    pub const id_dfr0: u32 = 0xE000_ED48;
    pub const id_afr0: u32 = 0xE000_ED4C;
    pub const id_mmfr0: u32 = 0xE000_ED50;
    pub const id_mmfr1: u32 = 0xE000_ED54;
    pub const id_mmfr2: u32 = 0xE000_ED58;
    pub const id_mmfr3: u32 = 0xE000_ED5C;
    pub const id_isar0: u32 = 0xE000_ED60;
    pub const id_isar1: u32 = 0xE000_ED64;
    pub const id_isar2: u32 = 0xE000_ED68;
    pub const id_isar3: u32 = 0xE000_ED6C;
    pub const id_isar4: u32 = 0xE000_ED70;
    pub const id_isar5: u32 = 0xE000_ED74;
    pub const mvfr0: u32 = 0xE000_EF40;
    pub const mvfr1: u32 = 0xE000_EF44;
    pub const mvfr2: u32 = 0xE000_EF48;
};

pub const FpuKind = enum(u2) {
    none = 0,
    single = 1,
    double = 2,
};

pub const Config = struct {
    v8_1m: bool = true,
    mve: bool = true,
    mve_fp: bool = true,
    lob: bool = true,
    pacbti: bool = true,
    fpu: FpuKind = .double,
    fp16: bool = true,
    security: bool = true,
    halting_debug: bool = true,
    tcm: bool = true,
    cache_maint: bool = true,
    coproc: bool = false,
    revidr: u32 = 0,
};

pub const Bank = struct {
    revidr: u32,
    pfr: [2]u32,
    dfr0: u32,
    afr0: u32,
    mmfr: [4]u32,
    isar: [6]u32,
    mvfr: [3]u32,

    pub fn fromConfig(cfg: Config) Bank {
        return .{
            .revidr = cfg.revidr,
            .pfr = .{
                (if (cfg.v8_1m) @as(u32, 0x2000_0000) else 0) | 0x0000_0030,
                0x0000_0200 | securityField(cfg),
            },
            .dfr0 = (if (cfg.v8_1m) @as(u32, 0x1000_0000) else 0) |
                (if (cfg.halting_debug) @as(u32, 0x0020_0000) else 0),
            .afr0 = 0,
            .mmfr = .{
                0x0010_0040 | (if (cfg.tcm) @as(u32, 0x0001_1000) else 0),
                0,
                0x0100_0000,
                if (cfg.cache_maint) 0x0000_0011 else 0,
            },
            .isar = .{
                0x0110_0110 | (if (cfg.coproc) @as(u32, 0x0004_0000) else 0) |
                    @as(u32, if (cfg.lob) 0x0000_3000 else 0x0000_1000),
                0x0221_2000,
                0x2023_2032 | @as(u32, if (cfg.v8_1m) 0x0000_0200 else 0x0000_0100),
                0x0111_1131,
                0x0131_0132,
                if (cfg.pacbti) 0x0010_0000 else 0,
            },
            .mvfr = .{
                mvfr0Of(cfg),
                mvfr1Of(cfg),
                if (cfg.fpu != .none) 0x0000_0040 else 0,
            },
        };
    }

    /// Reads any byte slice inside a modelled RO ID/feature register word.
    pub fn read(self: Bank, address: u32, into: []u8) bool {
        if (into.len == 0 or into.len > 4) return false;
        const offset = address & 3;
        if (offset + into.len > 4) return false;
        const value = self.wordAt(address & ~@as(u32, 3)) orelse return false;
        var raw: [4]u8 = undefined;
        std.mem.writeInt(u32, &raw, value, .little);
        @memcpy(into, raw[offset..][0..into.len]);
        return true;
    }

    pub fn covers(address: u32, len: usize) bool {
        if (len == 0 or len > 4) return false;
        const offset = address & 3;
        if (offset + len > 4) return false;
        return hasWord(address & ~@as(u32, 3));
    }

    fn wordAt(self: Bank, base: u32) ?u32 {
        return switch (base) {
            addr.revidr => self.revidr,
            addr.id_pfr0 => self.pfr[0],
            addr.id_pfr1 => self.pfr[1],
            addr.id_dfr0 => self.dfr0,
            addr.id_afr0 => self.afr0,
            addr.id_mmfr0 => self.mmfr[0],
            addr.id_mmfr1 => self.mmfr[1],
            addr.id_mmfr2 => self.mmfr[2],
            addr.id_mmfr3 => self.mmfr[3],
            addr.id_isar0 => self.isar[0],
            addr.id_isar1 => self.isar[1],
            addr.id_isar2 => self.isar[2],
            addr.id_isar3 => self.isar[3],
            addr.id_isar4 => self.isar[4],
            addr.id_isar5 => self.isar[5],
            addr.mvfr0 => self.mvfr[0],
            addr.mvfr1 => self.mvfr[1],
            addr.mvfr2 => self.mvfr[2],
            else => null,
        };
    }
};

fn securityField(cfg: Config) u32 {
    if (!cfg.security) return 0;
    return if (cfg.v8_1m) 0x30 else 0x10;
}

fn mvfr0Of(cfg: Config) u32 {
    return switch (cfg.fpu) {
        .none => if (cfg.mve) 0x0000_0001 else 0,
        .single => 0x1011_0021,
        .double => 0x1011_0221,
    };
}

fn mvfr1Of(cfg: Config) u32 {
    if (cfg.fpu == .none) return if (cfg.mve) 0x0000_0100 else 0;
    const mve_val: u32 = if (!cfg.mve) 0 else if (cfg.mve_fp) 0x200 else 0x100;
    const fp16_val: u32 = if (cfg.fp16) 0x0010_0000 else 0;
    const fphp_val: u32 = if (cfg.fpu == .double) 0x0200_0000 else 0x0100_0000;
    return 0x1000_0011 | fphp_val | fp16_val | mve_val;
}

fn hasWord(base: u32) bool {
    return base == addr.revidr or
        (base >= addr.id_pfr0 and base <= addr.id_isar5) or
        (base >= addr.mvfr0 and base <= addr.mvfr2);
}
