//! RA4T1 Flash Cache (`FCACHE = 0x4001_C100`, R01UH0999EJ0140 Rev.1.40 §38.4.1–38.4.4).
//!
//! Provides `FCACHEE` (`+0x000`), `FCACHEIV` (`+0x004`), `FLWT` (`+0x01C` = `0x4001_C11C`),
//! and `FSAR` (`+0x040`, reset `0xFFFF`, `PRCR.PRC4`-protected).
const chip = @import("../../../root.zig");
const sysc = @import("sysc.zig");

const registry = chip.periph.registry;

pub const win_base: u32 = 0x4001_C100;
pub const win_size: u32 = 0x100;

pub const ofs = struct {
    pub const fcachee: u32 = 0x000;
    pub const fcacheiv: u32 = 0x004;
    pub const flwt: u32 = 0x01C;
    pub const fsar: u32 = 0x040;
};

pub const Fcache = struct {
    fcachee: u16 = 0,
    flwt: u8 = 0,
    fsar: u16 = 0xFFFF,
    invalidations: u32 = 0,
    protection: ?*const sysc.Sysc = null,

    pub fn init(protection: ?*const sysc.Sysc) Fcache {
        return .{ .protection = protection };
    }

    pub fn block(self: *Fcache) registry.Block {
        return .{
            .name = "RA4T1 FCACHE",
            .base = win_base,
            .size = win_size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .peekFn = readThunk,
        };
    }

    fn readThunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Fcache = @ptrCast(@alignCast(ctx));
        return self.read(address, width);
    }

    fn writeThunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Fcache = @ptrCast(@alignCast(ctx));
        self.write(address, width, value);
    }

    pub fn read(self: *const Fcache, address: u32, width: u3) u32 {
        if (address < win_base or address - win_base >= win_size) return 0;
        const offset = address - win_base;
        const word: u32 = switch (offset) {
            ofs.fcachee => self.fcachee,
            ofs.fcachee + 1 => self.fcachee >> 8,
            ofs.fcacheiv, ofs.fcacheiv + 1 => 0,
            ofs.flwt => self.flwt,
            ofs.fsar => self.fsar,
            ofs.fsar + 1 => self.fsar >> 8,
            else => 0,
        };
        return switch (width) {
            1 => word & 0xFF,
            2 => word & 0xFFFF,
            else => word,
        };
    }

    pub fn write(self: *Fcache, address: u32, width: u3, value: u32) void {
        _ = width;
        if (address < win_base or address - win_base >= win_size) return;
        const offset = address - win_base;
        switch (offset) {
            ofs.fcachee => self.fcachee = @truncate(value & 0x0001),
            ofs.fcacheiv => {
                if ((value & 0x0001) != 0) self.invalidations +%= 1;
            },
            ofs.flwt => self.flwt = @truncate(value & 0x07),
            ofs.fsar => {
                if (self.protection) |guard| {
                    if (!guard.allows(sysc.prc.security)) return;
                }
                self.fsar = @truncate((value & 0x0101) | 0xFEFE);
            },
            else => {},
        }
    }
};
