//! CPU_DBG: CoreSight CPU debug status and authentication control (HUM Ch 2.9.5).
//!
//! Models DBGSTR (+0x000), DBGSTOPCR (+0x010), DBGAUTH0 (+0x020), and
//! ALCTRL (+0x100) at 0x4001_B000 (Non-secure alias folded by the bus).
//! Clearing DBGAUTH0 enable bits sets RO SWDBG [31] so software-initiated
//! debug lockdown reads back deterministically without real JTAG silicon.

const lanes = @import("lanes.zig");
const periph = @import("registry.zig");

pub const win_base: u32 = 0x4001_B000;
pub const win_span: u32 = 0x104;

pub const regs = struct {
    pub const dbgstr: u32 = 0x000;
    pub const dbgstopcr: u32 = 0x010;
    pub const dbgauth0: u32 = 0x020;
    pub const alctrl: u32 = 0x100;
};

pub const dbgstr_bits = struct {
    pub const cdbgpwrupreq: u32 = 1 << 28;
    pub const cdbgpwrupack: u32 = 1 << 29;
};

pub const dbgauth0_bits = struct {
    pub const dbgen0: u32 = 1 << 0;
    pub const dbgen1: u32 = 1 << 1;
    pub const niden0: u32 = 1 << 4;
    pub const niden1: u32 = 1 << 5;
    pub const deviceen: u32 = 1 << 16;
    pub const swdbg: u32 = 1 << 31;
    pub const all_enables: u32 = dbgen0 | dbgen1 | niden0 | niden1 | deviceen;
};

pub const alctrl_bits = struct {
    pub const al_mask: u32 = 0x0000_00FF;
    pub const failcnt_mask: u32 = 0xC000_0000;
    pub const al0: u32 = 0x00;
    pub const al1: u32 = 0x05;
    pub const al2: u32 = 0xA5;
};

pub const Unit = struct {
    dbgstr: u32 = 0,
    dbgstopcr: u32 = 0,
    dbgauth0: u32 = dbgauth0_bits.all_enables,
    alctrl: u32 = alctrl_bits.al2,
    lockdown_writes: u32 = 0,

    pub fn quiet(self: *const Unit) bool {
        return self.lockdown_writes == 0 and self.dbgstopcr == 0 and
            self.dbgauth0 == dbgauth0_bits.all_enables and self.alctrl == alctrl_bits.al2;
    }

    pub fn read(self: *const Unit, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const aligned = offset & ~@as(u32, 3);
        const word: u32 = switch (aligned) {
            regs.dbgstr => self.dbgstr,
            regs.dbgstopcr => self.dbgstopcr,
            regs.dbgauth0 => self.dbgauth0,
            regs.alctrl => self.alctrl,
            else => 0,
        };
        return lanes.part(word, @intCast(offset & 3), width);
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const aligned = offset & ~@as(u32, 3);
        const lane: u2 = @intCast(offset & 3);
        switch (aligned) {
            regs.dbgstopcr => self.dbgstopcr = lanes.merge(self.dbgstopcr, lane, width, value),
            regs.dbgauth0 => {
                const merged = lanes.merge(self.dbgauth0, lane, width, value);
                self.dbgauth0 = (merged & dbgauth0_bits.all_enables) | dbgauth0_bits.swdbg;
                self.lockdown_writes +%= 1;
            },
            regs.alctrl => {
                const merged = lanes.merge(self.alctrl, lane, width, value);
                self.alctrl = merged & (alctrl_bits.al_mask | alctrl_bits.failcnt_mask);
            },
            else => {},
        }
    }

    pub fn block(self: *Unit) periph.Block {
        return .{
            .name = "CPU_DBG",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Unit = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Unit = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
