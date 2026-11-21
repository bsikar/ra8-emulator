//! RA4T1 Flash Sequencer (`FACI` command area `0x407E_0000`, Flash I/O registers
//! `0x407F_E000`) and SRAM Control (`SRAM = 0x4000_2000`)
//! (R01UH0999EJ0140 Rev.1.40 Ch. 37 & Ch. 38; RA8EMU-A-71).
const chip = @import("../../../root.zig");

const registry = chip.periph.registry;

pub const faci_cmd_base: u32 = 0x407E_0000;
pub const faci_cmd_size: u32 = 0x4;
pub const faci_reg_base: u32 = 0x407F_E000;
pub const faci_reg_size: u32 = 0x200;
pub const sram_base: u32 = 0x4000_2000;
pub const sram_size: u32 = 0x100;

pub const sram_ofs = struct {
    pub const parioad: u32 = 0x00;
    pub const sramprcr: u32 = 0x04;
    pub const sramwtsc: u32 = 0x08;
    pub const sramprcr2: u32 = 0x0C;
    pub const eccmode: u32 = 0xC0;
};

pub const faci_ofs = struct {
    pub const fastat: u32 = 0x10;
    pub const faeint: u32 = 0x14;
    pub const frdyie: u32 = 0x18;
    pub const fsaddr: u32 = 0x30;
    pub const feaddr: u32 = 0x34;
    pub const fstatr: u32 = 0x80;
    pub const fentryr: u32 = 0x84;
    pub const fsuinitr: u32 = 0x8C;
    pub const fcmdr: u32 = 0xA0;
    pub const fckmhz: u32 = 0xD0;
};

pub const FlashCtrl = struct {
    fastat: u8 = 0x00,
    faeint: u8 = 0x88,
    frdyie: u8 = 0x00,
    fsaddr: u32 = 0,
    feaddr: u32 = 0,
    fstatr: u32 = 0x0000_8000, // FRDY = 1
    fentryr: u16 = 0,
    fckmhz: u8 = 0x02,
    commands: u32 = 0,
    parioad: u8 = 0,
    sramprcr: u8 = 0,
    sramwtsc: u8 = 0x01,
    sramprcr2: u8 = 0,
    eccmode: u8 = 0,

    pub fn init() FlashCtrl {
        return .{};
    }

    pub fn cmdBlock(self: *FlashCtrl) registry.Block {
        return .{
            .name = "RA4T1 FACI CMD",
            .base = faci_cmd_base,
            .size = faci_cmd_size,
            .context = self,
            .readFn = readCmdThunk,
            .writeFn = writeCmdThunk,
            .peekFn = readCmdThunk,
        };
    }

    pub fn regBlock(self: *FlashCtrl) registry.Block {
        return .{
            .name = "RA4T1 FACI REGS",
            .base = faci_reg_base,
            .size = faci_reg_size,
            .context = self,
            .readFn = readRegThunk,
            .writeFn = writeRegThunk,
            .peekFn = readRegThunk,
        };
    }

    pub fn sramBlock(self: *FlashCtrl) registry.Block {
        return .{
            .name = "RA4T1 SRAM CTRL",
            .base = sram_base,
            .size = sram_size,
            .context = self,
            .readFn = readSramThunk,
            .writeFn = writeSramThunk,
            .peekFn = readSramThunk,
        };
    }

    fn readCmdThunk(_: *anyopaque, _: u32, _: u3) u32 {
        return 0;
    }

    fn writeCmdThunk(ctx: *anyopaque, _: u32, _: u3, _: u32) void {
        const self: *FlashCtrl = @ptrCast(@alignCast(ctx));
        self.commands +%= 1;
        self.fastat |= 0x40; // CMDLK on unmodeled program/erase attempt outside ROM
        self.fstatr |= 0x0000_8000;
    }

    fn readRegThunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const FlashCtrl = @ptrCast(@alignCast(ctx));
        if (address < faci_reg_base or address - faci_reg_base >= faci_reg_size) return 0;
        const val: u32 = switch (address - faci_reg_base) {
            faci_ofs.fastat => self.fastat,
            faci_ofs.faeint => self.faeint,
            faci_ofs.frdyie => self.frdyie,
            faci_ofs.fsaddr => self.fsaddr,
            faci_ofs.feaddr => self.feaddr,
            faci_ofs.fstatr => self.fstatr,
            faci_ofs.fentryr => self.fentryr,
            faci_ofs.fckmhz => self.fckmhz,
            else => 0,
        };
        return maskWidth(val, width);
    }

    fn writeRegThunk(ctx: *anyopaque, address: u32, _: u3, value: u32) void {
        const self: *FlashCtrl = @ptrCast(@alignCast(ctx));
        if (address < faci_reg_base or address - faci_reg_base >= faci_reg_size) return;
        switch (address - faci_reg_base) {
            faci_ofs.faeint => self.faeint = @truncate(value),
            faci_ofs.frdyie => self.frdyie = @truncate(value),
            faci_ofs.fsaddr => self.fsaddr = value,
            faci_ofs.feaddr => self.feaddr = value,
            faci_ofs.fentryr => {
                if ((value >> 8) == 0xAA) self.fentryr = @truncate(value & 0x0081);
            },
            faci_ofs.fckmhz => self.fckmhz = @truncate(value),
            else => {},
        }
    }

    fn readSramThunk(ctx: *anyopaque, address: u32, _: u3) u32 {
        const self: *const FlashCtrl = @ptrCast(@alignCast(ctx));
        if (address < sram_base or address - sram_base >= sram_size) return 0;
        return switch (address - sram_base) {
            sram_ofs.parioad => self.parioad,
            sram_ofs.sramprcr => self.sramprcr,
            sram_ofs.sramwtsc => self.sramwtsc,
            sram_ofs.sramprcr2 => self.sramprcr2,
            sram_ofs.eccmode => self.eccmode,
            else => 0,
        };
    }

    fn writeSramThunk(ctx: *anyopaque, address: u32, _: u3, value: u32) void {
        const self: *FlashCtrl = @ptrCast(@alignCast(ctx));
        if (address < sram_base or address - sram_base >= sram_size) return;
        const b: u8 = @truncate(value);
        switch (address - sram_base) {
            sram_ofs.sramprcr => if ((b >> 1) == 0x78) {
                self.sramprcr = b & 1;
            },
            sram_ofs.parioad => if ((self.sramprcr & 1) != 0) {
                self.parioad = b & 1;
            },
            sram_ofs.sramprcr2 => if ((b >> 1) == 0x78) {
                self.sramprcr2 = b & 1;
            },
            sram_ofs.sramwtsc => if ((self.sramprcr2 & 1) != 0) {
                self.sramwtsc = b & 1;
            },
            sram_ofs.eccmode => self.eccmode = b & 3,
            else => {},
        }
    }
};

fn maskWidth(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}
