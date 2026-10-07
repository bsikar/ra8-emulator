//! SDRAMC: the external SDRAM controller on R_BUS (RA8EMU-283), and the
//! SDCLK output control on R_SYSTEM.
//!
//! Offsets are ra8_sdramc_regs.h's ra8_sdramc_off_t from the R_BUS.SDRAM
//! base 0x4000_3C00 (HUM Ch 15.3.11..15.3.22): SDCCR +0x00, SDCMOD +0x01,
//! SDAMOD +0x02, SDSELF +0x10, SDRFCR +0x14, SDRFEN +0x16, SDICR +0x20,
//! SDIR +0x24, SDADR +0x40, SDTR +0x44, SDMOD +0x48 and SDSR +0x50. SDCKOCR
//! is the byte at 0x4001_E053. ra8_io_sdram_demo, sdram_benchmark and
//! camera_capture write all of them while bringing the part up; unmodelled,
//! the stores fell to the sparse bus and showed in the report.
//!
//! THE SDRAM ITSELF is the 64 MB window at 0x6800_0000 that memmap.zig maps
//! as plain RAM, so it works before, during and after this sequence. Nothing
//! here gates it on SDCCR.EXENB or a finished init.
//!
//! SDSR ALWAYS READS 0. Its MRSST (bit 0), INIST (bit 3) and SRFST (bit 4)
//! say a mode-register set, the init sequence or a self-refresh transition is
//! still running. The model has no SDRAM timing, so each finishes the moment
//! it starts and the driver's poll loops see them clear on the first read.
//!
//! WRITABLE BITS ARE NOT READ FROM THE HUM. Every store lands at the width the
//! firmware used and reads back as written, so a bit the hardware keeps at 0
//! would read back 1 here. Recorded, not enforced.
const periph = @import("registry.zig");
const lanes = @import("lanes.zig");

pub const base: u32 = 0x4000_3C00;
pub const span: u32 = 0x54;
pub const sdckocr_address: u32 = 0x4001_E053;

pub const off = struct {
    pub const sdccr: u32 = 0x00;
    pub const sdcmod: u32 = 0x01;
    pub const sdamod: u32 = 0x02;
    pub const sdself: u32 = 0x10;
    pub const sdrfcr: u32 = 0x14;
    pub const sdrfen: u32 = 0x16;
    pub const sdicr: u32 = 0x20;
    pub const sdir: u32 = 0x24;
    pub const sdadr: u32 = 0x40;
    pub const sdtr: u32 = 0x44;
    pub const sdmod: u32 = 0x48;
    pub const sdsr: u32 = 0x50;
};

const word_count: usize = span / 4;

pub const Sdramc = struct {
    words: [word_count]u32 = @splat(0),
    sdckocr: u8 = 0,
    /// Stores that landed on either window.
    writes: u32 = 0,

    pub fn quiet(self: *const Sdramc) bool {
        return self.writes == 0;
    }

    pub fn read(self: *Sdramc, address: u32, width: u3) u32 {
        if (address == sdckocr_address) return self.sdckocr;
        const offset = address -% base;
        if (offset >= span or offset & ~@as(u32, 0x3) == off.sdsr) return 0;
        return lanes.part(self.words[offset / 4], offset & 0x3, width);
    }

    pub fn write(self: *Sdramc, address: u32, width: u3, value: u32) void {
        if (address == sdckocr_address) {
            self.sdckocr = @truncate(value);
            self.writes +%= 1;
            return;
        }
        const offset = address -% base;
        if (offset >= span or offset & ~@as(u32, 0x3) == off.sdsr) return;
        const word = &self.words[offset / 4];
        word.* = lanes.merge(word.*, offset & 0x3, width, value);
        self.writes +%= 1;
    }

    /// The controller window and the SDCKOCR byte.
    pub fn attach(self: *Sdramc, bus: *periph.Bus) periph.Error!void {
        try bus.add(self.window("SDRAMC", base, span));
        try bus.add(self.window("SDCKOCR", sdckocr_address, 1));
    }

    fn window(self: *Sdramc, name: []const u8, at: u32, size: u32) periph.Block {
        return .{
            .name = name,
            .base = at,
            .size = size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Sdramc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Sdramc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
