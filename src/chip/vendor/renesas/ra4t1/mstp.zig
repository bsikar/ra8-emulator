//! RA4T1 Module-Stop Control Registers `MSTPCRA`..`MSTPCRE` (`MSTP = 0x4008_4000`)
//! and bus clock gate (R01UH0999EJ0140 Rev.1.40 Ch. 10, pp. 186–191; RA8EMU-A-71).
//!
//! Reset values leave SRAM0 + DMAC/DTC active in `MSTPCRA = 0xFFBF_FF7E` and
//! peripheral modules stopped (`0xFFFF_FFFF` in `MSTPCRB..E`). `SCI0`, `SCI9`,
//! `GPT16E0..5`, and `AGT0..1` refuse register access while stopped.
const chip = @import("../../../root.zig");

const registry = chip.periph.registry;

pub const win_base: u32 = 0x4008_4000;
pub const win_size: u32 = 0x20;

pub const ofs = struct {
    pub const a: u32 = 0x000;
    pub const b: u32 = 0x004;
    pub const c: u32 = 0x008;
    pub const d: u32 = 0x00C;
    pub const e: u32 = 0x010;
};

pub const bit = struct {
    pub const i3c0: u32 = 1 << 4;
    pub const spi1: u32 = 1 << 18;
    pub const spi0: u32 = 1 << 19;
    pub const sci9: u32 = 1 << 22;
    pub const sci0: u32 = 1 << 31;
    pub const agt1: u32 = 1 << 2;
    pub const agt0: u32 = 1 << 3;
};

pub const Mstp = struct {
    a: u32 = 0xFFBF_FF7E,
    b: u32 = 0xFFFF_FFFF,
    c: u32 = 0xFFFF_FFFF,
    d: u32 = 0xFFFF_FFFF,
    e: u32 = 0xFFFF_FFFF,
    stopped_reads: u64 = 0,
    stopped_writes: u64 = 0,

    pub fn init() Mstp {
        return .{};
    }

    pub fn block(self: *Mstp) registry.Block {
        return .{
            .name = "RA4T1 MSTP",
            .base = win_base,
            .size = win_size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .peekFn = readThunk,
        };
    }

    pub fn gate(self: *Mstp) registry.Gate {
        return .{
            .context = self,
            .stoppedFn = stoppedThunk,
            .noteFn = noteThunk,
        };
    }

    pub fn sciActive(self: *const Mstp, channel: u1) bool {
        const mask = if (channel == 0) bit.sci0 else bit.sci9;
        return (self.b & mask) == 0;
    }

    pub fn agtActive(self: *const Mstp, channel: u1) bool {
        const mask = if (channel == 0) bit.agt0 else bit.agt1;
        return (self.d & mask) == 0;
    }

    pub fn gptActive(self: *const Mstp, channel: u3) bool {
        if (channel > 5) return false;
        const shift: u5 = @intCast(31 - @as(u5, channel));
        return (self.e & (@as(u32, 1) << shift)) == 0;
    }

    pub fn isStoppedAddress(self: *const Mstp, address: u32) bool {
        if (address >= 0x4011_8000 and address < 0x4011_8100) return !self.sciActive(0);
        if (address >= 0x4011_8900 and address < 0x4011_8A00) return !self.sciActive(1);
        if (address >= 0x400E_8000 and address < 0x400E_8100) return !self.agtActive(0);
        if (address >= 0x400E_8100 and address < 0x400E_8200) return !self.agtActive(1);
        if (address >= 0x4016_9000 and address < 0x4016_9600) {
            const channel: u3 = @truncate((address - 0x4016_9000) >> 8);
            return !self.gptActive(channel);
        }
        return false;
    }

    fn stoppedThunk(ctx: *anyopaque, address: u32) bool {
        const self: *const Mstp = @ptrCast(@alignCast(ctx));
        return self.isStoppedAddress(address);
    }

    fn noteThunk(ctx: *anyopaque, _: u32, access: registry.Access) void {
        const self: *Mstp = @ptrCast(@alignCast(ctx));
        switch (access) {
            .read => self.stopped_reads +%= 1,
            .write => self.stopped_writes +%= 1,
        }
    }

    fn readThunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Mstp = @ptrCast(@alignCast(ctx));
        return self.read(address, width);
    }

    fn writeThunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Mstp = @ptrCast(@alignCast(ctx));
        self.write(address, width, value);
    }

    pub fn read(self: *const Mstp, address: u32, width: u3) u32 {
        if (address < win_base or address - win_base >= win_size) return 0;
        const offset = address - win_base;
        const word = switch (offset & ~@as(u32, 3)) {
            ofs.a => self.a,
            ofs.b => self.b,
            ofs.c => self.c,
            ofs.d => self.d,
            ofs.e => self.e,
            else => 0,
        };
        const shift: u5 = @intCast((offset & 3) * 8);
        return switch (width) {
            1 => (word >> shift) & 0xFF,
            2 => (word >> shift) & 0xFFFF,
            else => word,
        };
    }

    pub fn write(self: *Mstp, address: u32, width: u3, value: u32) void {
        if (address < win_base or address - win_base >= win_size) return;
        const offset = address - win_base;
        const aligned = offset & ~@as(u32, 3);
        const target: *u32 = switch (aligned) {
            ofs.a => &self.a,
            ofs.b => &self.b,
            ofs.c => &self.c,
            ofs.d => &self.d,
            ofs.e => &self.e,
            else => return,
        };
        const shift: u5 = @intCast((offset & 3) * 8);
        const mask_w: u32 = switch (width) {
            1 => 0xFF,
            2 => 0xFFFF,
            else => 0xFFFF_FFFF,
        };
        const shifted = mask_w << shift;
        target.* = (target.* & ~shifted) | ((value & mask_w) << shift);
    }
};
