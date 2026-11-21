//! Himax HX6538 System Control Units (`SCU_AON`, `SCU_SB`, `SCU_LSC`).
//!
//! Models documented reset/CPUWAIT/INITSVTOR/clock-enable/IDAU registers from
//! `WE2_device_addr.h`, `hx_drv_scu_export.h`, and `libdriver.a`:
//!   - `CM55S_STATE` (AON +0x210, reset 0 = RESET; 1 = NORMAL)
//!   - `CM55S_CPUWAIT` (AON +0xD08, reset 1 = held; 0 = released)
//!   - `CM55S_INITSVTOR` / `INITNSVTOR` (AON +0xD00 / +0xD04)
//!   - `CM55M_STATE` / `CPUWAIT` / `INITSVTOR` / `INITNSVTOR`
//!   - `CM55M_IDAU` / `CM55S_IDAU` (+0x800 / +0x804, reset 1)
//!   - `PDLSC_CLKEN` (+0x040/+0x044, reset 0xFFFF), `TIMER_CLK_EN_CTRL` (SB +0x13C)
const registry = @import("../../../periph/registry.zig");

pub const aon_base: u32 = 0x5610_0000;
pub const sb_base: u32 = 0x5600_6000;
pub const lsc_base: u32 = 0x5200_1000;
pub const size: u32 = 0x1000;

pub const aon_regs = struct {
    pub const pdsb_clk: u32 = 0x004;
    pub const pdlsc_clken0: u32 = 0x040;
    pub const pdlsc_clken1: u32 = 0x044;
    pub const cm55s_state: u32 = 0x210;
    pub const u55_state: u32 = 0x214;
    pub const cm55m_state: u32 = 0x218;
    pub const cm55s_por_state: u32 = 0x220;
    pub const cm55m_por_state: u32 = 0x228;
    pub const cm55m_idau: u32 = 0x800;
    pub const cm55s_idau: u32 = 0x804;
    pub const cm55m_initsvtor: u32 = 0xC00;
    pub const cm55m_initnsvtor: u32 = 0xC04;
    pub const cm55m_cpuwait: u32 = 0xC08;
    pub const cm55s_initsvtor: u32 = 0xD00;
    pub const cm55s_initnsvtor: u32 = 0xD04;
    pub const cm55s_cpuwait: u32 = 0xD08;
};

pub const sb_regs = struct {
    pub const timer_clk_en_ctrl: u32 = 0x13C;
};

pub const lsc_regs = struct {
    pub const cm55s_reset_mask: u32 = 0x300;
};

pub const Scu = struct {
    pdsb_clk: u32 = 0,
    pdlsc_clken0: u32 = 0x0000_FFFF,
    pdlsc_clken1: u32 = 0x0000_FFFF,
    cm55s_state: u32 = 0,
    u55_state: u32 = 0,
    cm55m_state: u32 = 1,
    cm55s_por_state: u32 = 0,
    cm55m_por_state: u32 = 1,
    cm55m_idau: u32 = 1,
    cm55s_idau: u32 = 1,
    cm55m_initsvtor: u32 = 0x1000_0000,
    cm55m_initnsvtor: u32 = 0x0000_0000,
    cm55m_cpuwait: u32 = 0,
    cm55s_initsvtor: u32 = 0x1000_0000,
    cm55s_initnsvtor: u32 = 0x0000_0000,
    cm55s_cpuwait: u32 = 1,
    timer_clk_en_ctrl: u32 = 0,
    cm55s_reset_mask: u32 = 0,

    pub fn aonBlock(self: *Scu) registry.Block {
        return .{
            .name = "hx_scu_aon",
            .base = aon_base,
            .size = size,
            .context = self,
            .readFn = aonReadThunk,
            .writeFn = aonWriteThunk,
        };
    }

    pub fn sbBlock(self: *Scu) registry.Block {
        return .{
            .name = "hx_scu_sb",
            .base = sb_base,
            .size = size,
            .context = self,
            .readFn = sbReadThunk,
            .writeFn = sbWriteThunk,
        };
    }

    pub fn lscBlock(self: *Scu) registry.Block {
        return .{
            .name = "hx_scu_lsc",
            .base = lsc_base,
            .size = size,
            .context = self,
            .readFn = lscReadThunk,
            .writeFn = lscWriteThunk,
        };
    }

    /// True once CM55M sets `CM55S_STATE == 1` and clears `CM55S_CPUWAIT == 0`.
    pub fn cm55sRunning(self: *const Scu) bool {
        return (self.cm55s_state & 1) == 1 and (self.cm55s_cpuwait & 1) == 0;
    }

    pub fn readAon(self: *const Scu, offset: u32) u32 {
        return switch (offset) {
            aon_regs.pdsb_clk => self.pdsb_clk,
            aon_regs.pdlsc_clken0 => self.pdlsc_clken0,
            aon_regs.pdlsc_clken1 => self.pdlsc_clken1,
            aon_regs.cm55s_state => self.cm55s_state,
            aon_regs.u55_state => self.u55_state,
            aon_regs.cm55m_state => self.cm55m_state,
            aon_regs.cm55s_por_state => self.cm55s_por_state,
            aon_regs.cm55m_por_state => self.cm55m_por_state,
            aon_regs.cm55m_idau => self.cm55m_idau,
            aon_regs.cm55s_idau => self.cm55s_idau,
            aon_regs.cm55m_initsvtor => self.cm55m_initsvtor,
            aon_regs.cm55m_initnsvtor => self.cm55m_initnsvtor,
            aon_regs.cm55m_cpuwait => self.cm55m_cpuwait,
            aon_regs.cm55s_initsvtor => self.cm55s_initsvtor,
            aon_regs.cm55s_initnsvtor => self.cm55s_initnsvtor,
            aon_regs.cm55s_cpuwait => self.cm55s_cpuwait,
            else => 0,
        };
    }

    pub fn writeAon(self: *Scu, offset: u32, value: u32) void {
        switch (offset) {
            aon_regs.pdsb_clk => self.pdsb_clk = value,
            aon_regs.pdlsc_clken0 => self.pdlsc_clken0 = value,
            aon_regs.pdlsc_clken1 => self.pdlsc_clken1 = value,
            aon_regs.cm55s_state => self.cm55s_state = value & 1,
            aon_regs.u55_state => self.u55_state = value,
            aon_regs.cm55m_state => self.cm55m_state = value & 1,
            aon_regs.cm55s_por_state => self.cm55s_por_state = value & 1,
            aon_regs.cm55m_por_state => self.cm55m_por_state = value & 1,
            aon_regs.cm55m_idau => self.cm55m_idau = value,
            aon_regs.cm55s_idau => self.cm55s_idau = value,
            aon_regs.cm55m_initsvtor => self.cm55m_initsvtor = value,
            aon_regs.cm55m_initnsvtor => self.cm55m_initnsvtor = value,
            aon_regs.cm55m_cpuwait => self.cm55m_cpuwait = value & 1,
            aon_regs.cm55s_initsvtor => self.cm55s_initsvtor = value,
            aon_regs.cm55s_initnsvtor => self.cm55s_initnsvtor = value,
            aon_regs.cm55s_cpuwait => self.cm55s_cpuwait = value & 1,
            else => {},
        }
    }

    pub fn readSb(self: *const Scu, offset: u32) u32 {
        return if (offset == sb_regs.timer_clk_en_ctrl) self.timer_clk_en_ctrl else 0;
    }

    pub fn writeSb(self: *Scu, offset: u32, value: u32) void {
        if (offset == sb_regs.timer_clk_en_ctrl) self.timer_clk_en_ctrl = value;
    }

    pub fn readLsc(self: *const Scu, offset: u32) u32 {
        return if (offset == lsc_regs.cm55s_reset_mask) self.cm55s_reset_mask & 1 else 0;
    }

    pub fn writeLsc(self: *Scu, offset: u32, value: u32) void {
        if (offset == lsc_regs.cm55s_reset_mask) self.cm55s_reset_mask = value & 1;
    }
};

fn aonReadThunk(context: *anyopaque, address: u32, _: u3) u32 {
    const self: *const Scu = @ptrCast(@alignCast(context));
    return self.readAon(address - aon_base);
}

fn aonWriteThunk(context: *anyopaque, address: u32, _: u3, value: u32) void {
    const self: *Scu = @ptrCast(@alignCast(context));
    self.writeAon(address - aon_base, value);
}

fn sbReadThunk(context: *anyopaque, address: u32, _: u3) u32 {
    const self: *const Scu = @ptrCast(@alignCast(context));
    return self.readSb(address - sb_base);
}

fn sbWriteThunk(context: *anyopaque, address: u32, _: u3, value: u32) void {
    const self: *Scu = @ptrCast(@alignCast(context));
    self.writeSb(address - sb_base, value);
}

fn lscReadThunk(context: *anyopaque, address: u32, _: u3) u32 {
    const self: *const Scu = @ptrCast(@alignCast(context));
    return self.readLsc(address - lsc_base);
}

fn lscWriteThunk(context: *anyopaque, address: u32, _: u3, value: u32) void {
    const self: *Scu = @ptrCast(@alignCast(context));
    self.writeLsc(address - lsc_base, value);
}
