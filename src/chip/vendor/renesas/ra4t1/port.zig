//! RA4T1 I/O Ports (`PORT0..5, 8 = 0x4008_0000 + 0x20*m`) and Pin Function Select
//! (`PFS = 0x4008_0800`, `PWPR = 0x4008_0D03`, `PWPRS = 0x4008_0D05`, `PmSAR = 0x4008_0D10`)
//! (R01UH0999EJ0140 Rev.1.40 Ch. 18, pp. 414–435; R20UT5524EG0100; RA8EMU-A-71).
//!
//! Reset `PmnPFS` values (`P000..P003 = 0x0000_8000`, `P108 = 0x0001_0410`,
//! `P201 = 0x0000_0010`, `P300 = 0x0001_0010`) and FPB-RA4T1 board pull-ups
//! (`P200`, `P201`, `P206`, `P208` high so `PORT2.PIDR == 0x01C3` when `P207 = 1`)
//! match physical bench capture on `R7FA4T1BB3CFM`.
const chip = @import("../../../root.zig");
const sysc = @import("sysc.zig");

const registry = chip.periph.registry;

pub const port_base: u32 = 0x4008_0000;
pub const port_size: u32 = 0x120;
pub const pfs_base: u32 = 0x4008_0800;
pub const pfs_size: u32 = 0x540;

pub const slot_count: usize = 7; // PORT0..PORT5 and PORT8

pub const reg_ofs = struct {
    pub const pcntr1: u32 = 0x00;
    pub const pcntr2: u32 = 0x04;
    pub const pcntr3: u32 = 0x08;
    pub const pcntr4: u32 = 0x0C;
    pub const pwpr: u32 = 0x4008_0D03 - pfs_base;
    pub const pwprs: u32 = 0x4008_0D05 - pfs_base;
    pub const pmsar: u32 = 0x4008_0D10 - pfs_base;
};

pub const pfs_mask = struct {
    pub const podr: u32 = 1 << 0;
    pub const pidr: u32 = 1 << 1;
    pub const pdr: u32 = 1 << 2;
    pub const pcr: u32 = 1 << 4;
    pub const writemask: u32 = 0x1F01_CF55;
};

pub const Port = struct {
    pdr: [slot_count]u16 = @splat(0),
    podr: [slot_count]u16 = @splat(0),
    eidr: [slot_count]u16 = @splat(0),
    /// Board-level default high inputs (pull-ups / strapped pins).
    /// `PORT2`: `P200` (NMI), `P201` (MD pull-up), `P206` (LED2 net), `P208` (Arduino RESET#).
    external_high: [slot_count]u16 = .{
        0x0000, // PORT0
        0x0100, // PORT1: P108 (SWDIO pull-up)
        0x0143, // PORT2: P200, P201, P206, P208 -> 0x01C3 when P207 = 1
        0x0001, // PORT3: P300 (SWCLK pull-up)
        0x0000, // PORT4
        0x0000, // PORT5
        0x0000, // PORT8
    },
    pfs: [slot_count][16]u32 = initPfs(),
    pmsar: [slot_count]u16 = @splat(0xFFFF),
    pwpr: u8 = 0x80,
    pwprs: u8 = 0x80,
    pfs_writes: u32 = 0,
    pfs_blocked: u32 = 0,
    protection: ?*const sysc.Sysc = null,

    pub fn init(protection: ?*const sysc.Sysc) Port {
        return .{ .protection = protection };
    }

    pub fn portBlock(self: *Port) registry.Block {
        return .{
            .name = "RA4T1 PORT",
            .base = port_base,
            .size = port_size,
            .context = self,
            .readFn = readPortThunk,
            .writeFn = writePortThunk,
            .peekFn = readPortThunk,
        };
    }

    pub fn pfsBlock(self: *Port) registry.Block {
        return .{
            .name = "RA4T1 PFS",
            .base = pfs_base,
            .size = pfs_size,
            .context = self,
            .readFn = readPfsThunk,
            .writeFn = writePfsThunk,
            .peekFn = readPfsThunk,
        };
    }

    pub fn pidrOf(self: *const Port, port_num: u8) u16 {
        const idx = slotOf(port_num) orelse return 0;
        const out_mask = self.pdr[idx];
        const pullup_mask = self.pullups(idx);
        const in_high = self.external_high[idx] | pullup_mask;
        return (self.podr[idx] & out_mask) | (in_high & ~out_mask);
    }

    pub fn setInput(self: *Port, port_num: u8, pin: u4, high: bool) void {
        const idx = slotOf(port_num) orelse return;
        const bit = @as(u16, 1) << pin;
        if (high) {
            self.external_high[idx] |= bit;
        } else {
            self.external_high[idx] &= ~bit;
        }
    }

    fn pullups(self: *const Port, idx: usize) u16 {
        var mask: u16 = 0;
        for (0..16) |pin| {
            if ((self.pfs[idx][pin] & pfs_mask.pcr) != 0) mask |= @as(u16, 1) << @intCast(pin);
        }
        return mask;
    }

    fn readPortThunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Port = @ptrCast(@alignCast(ctx));
        return self.readPort(address, width);
    }

    fn writePortThunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Port = @ptrCast(@alignCast(ctx));
        self.writePort(address, width, value);
    }

    pub fn readPort(self: *const Port, address: u32, width: u3) u32 {
        if (address < port_base or address - port_base >= port_size) return 0;
        const off = address - port_base;
        const port_num: u8 = @intCast(off / 0x20);
        const idx = slotOf(port_num) orelse return 0;
        const reg = off % 0x20;
        const aligned = reg & ~@as(u32, 3);
        const word: u32 = switch (aligned) {
            reg_ofs.pcntr1 => (@as(u32, self.podr[idx]) << 16) | self.pdr[idx],
            reg_ofs.pcntr2 => (@as(u32, self.eidr[idx]) << 16) | self.pidrOf(port_num),
            else => 0,
        };
        const shift: u5 = @intCast((reg & 3) * 8);
        return maskWidth(word >> shift, width);
    }

    pub fn writePort(self: *Port, address: u32, width: u3, value: u32) void {
        if (address < port_base or address - port_base >= port_size) return;
        const off = address - port_base;
        const port_num: u8 = @intCast(off / 0x20);
        const idx = slotOf(port_num) orelse return;
        const reg = off % 0x20;
        const aligned = reg & ~@as(u32, 3);
        const word = widenWrite(self.readPort(port_base + port_num * 0x20 + aligned, 4), reg & 3, width, value);
        switch (aligned) {
            reg_ofs.pcntr1 => self.applyPcntr1(idx, word),
            reg_ofs.pcntr3 => self.applyPcntr3(idx, word),
            reg_ofs.pcntr4 => {
                if (port_num >= 1 and port_num <= 4) self.applyEosrEorr(idx, word);
            },
            else => {},
        }
    }

    fn applyPcntr1(self: *Port, idx: usize, word: u32) void {
        self.pdr[idx] = @truncate(word);
        self.podr[idx] = @truncate(word >> 16);
        self.syncPfsPins(idx);
    }

    fn applyPcntr3(self: *Port, idx: usize, word: u32) void {
        const set_mask: u16 = @truncate(word);
        const clr_mask: u16 = @truncate(word >> 16);
        self.podr[idx] = (self.podr[idx] | set_mask) & ~clr_mask;
        self.syncPfsPins(idx);
    }

    fn applyEosrEorr(self: *Port, idx: usize, word: u32) void {
        const set_mask: u16 = @truncate(word);
        const clr_mask: u16 = @truncate(word >> 16);
        self.eidr[idx] = (self.eidr[idx] | set_mask) & ~clr_mask;
    }

    fn syncPfsPins(self: *Port, idx: usize) void {
        for (0..16) |pin| {
            const bit = @as(u16, 1) << @intCast(pin);
            var val = self.pfs[idx][pin] & ~(pfs_mask.pdr | pfs_mask.podr);
            if ((self.pdr[idx] & bit) != 0) val |= pfs_mask.pdr;
            if ((self.podr[idx] & bit) != 0) val |= pfs_mask.podr;
            self.pfs[idx][pin] = val;
        }
    }

    fn readPfsThunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Port = @ptrCast(@alignCast(ctx));
        return self.readPfs(address, width);
    }

    fn writePfsThunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Port = @ptrCast(@alignCast(ctx));
        self.writePfs(address, width, value);
    }

    pub fn readPfs(self: *const Port, address: u32, width: u3) u32 {
        if (address < pfs_base or address - pfs_base >= pfs_size) return 0;
        const off = address - pfs_base;
        if (off < 0x500) return self.readPinPfs(off, width);
        if (off == reg_ofs.pwpr) return self.pwpr;
        if (off == reg_ofs.pwprs) return self.pwprs;
        if (off >= reg_ofs.pmsar and off < reg_ofs.pmsar + 0x14) {
            const port_num: u8 = @intCast((off - reg_ofs.pmsar) / 2);
            const idx = slotOf(port_num) orelse return 0xFFFF;
            return self.pmsar[idx];
        }
        return 0;
    }

    fn readPinPfs(self: *const Port, off: u32, width: u3) u32 {
        const port_num: u8 = @intCast(off / 0x40);
        const idx = slotOf(port_num) orelse return 0;
        const pin: usize = @intCast((off % 0x40) / 4);
        var val = self.pfs[idx][pin] & ~pfs_mask.pidr;
        if ((self.pidrOf(port_num) & (@as(u16, 1) << @intCast(pin))) != 0) {
            val |= pfs_mask.pidr;
        }
        const shift: u5 = @intCast((off & 3) * 8);
        return maskWidth(val >> shift, width);
    }

    pub fn writePfs(self: *Port, address: u32, width: u3, value: u32) void {
        if (address < pfs_base or address - pfs_base >= pfs_size) return;
        const off = address - pfs_base;
        if (off < 0x500) {
            self.writePinPfs(off, width, value);
            return;
        }
        if (off == reg_ofs.pwpr) {
            self.pwpr = updatePwpr(self.pwpr, @truncate(value));
            return;
        }
        if (off == reg_ofs.pwprs) {
            if (self.allowsSecurity()) self.pwprs = updatePwpr(self.pwprs, @truncate(value));
            return;
        }
        if (off >= reg_ofs.pmsar and off < reg_ofs.pmsar + 0x14) {
            if (!self.allowsSecurity()) return;
            const port_num: u8 = @intCast((off - reg_ofs.pmsar) / 2);
            const idx = slotOf(port_num) orelse return;
            self.pmsar[idx] = @truncate(value);
        }
    }

    fn writePinPfs(self: *Port, off: u32, width: u3, value: u32) void {
        const port_num: u8 = @intCast(off / 0x40);
        const idx = slotOf(port_num) orelse return;
        const pin: u4 = @intCast((off % 0x40) / 4);
        const is_nonsecure = (self.pmsar[idx] & (@as(u16, 1) << pin)) != 0;
        const unlocked = if (is_nonsecure) (self.pwpr & 0x40) != 0 else (self.pwprs & 0x40) != 0;
        if (!unlocked) {
            self.pfs_blocked +%= 1;
            return;
        }
        self.pfs_writes +%= 1;
        const current = self.pfs[idx][pin];
        const next = widenWrite(current, off & 3, width, value) & pfs_mask.writemask;
        self.pfs[idx][pin] = next & ~pfs_mask.pidr;
        const bit = @as(u16, 1) << pin;
        if ((next & pfs_mask.pdr) != 0) self.pdr[idx] |= bit else self.pdr[idx] &= ~bit;
        if ((next & pfs_mask.podr) != 0) self.podr[idx] |= bit else self.podr[idx] &= ~bit;
    }

    fn allowsSecurity(self: *const Port) bool {
        if (self.protection) |guard| return guard.allows(sysc.prc.security);
        return true;
    }
};

fn slotOf(port_num: u8) ?usize {
    return switch (port_num) {
        0...5 => port_num,
        8 => 6,
        else => null,
    };
}

fn initPfs() [slot_count][16]u32 {
    var table: [slot_count][16]u32 = @splat(@splat(0));
    table[0][0] = 0x0000_8000;
    table[0][1] = 0x0000_8000;
    table[0][2] = 0x0000_8000;
    table[0][3] = 0x0000_8000;
    table[1][8] = 0x0001_0410;
    table[2][1] = 0x0000_0010;
    table[3][0] = 0x0001_0010;
    return table;
}

fn updatePwpr(current: u8, byte: u8) u8 {
    // B0WI must already be 0 (or cleared to 0 while PFSWE stays 0) before setting PFSWE.
    if ((byte & 0x80) != 0) return 0x80;
    if ((current & 0x80) != 0) return byte & 0x80;
    return byte & 0x40;
}

fn maskWidth(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}

fn widenWrite(current: u32, byte_off: u32, width: u3, value: u32) u32 {
    const shift: u5 = @intCast(byte_off * 8);
    const width_mask: u32 = switch (width) {
        1 => 0xFF,
        2 => 0xFFFF,
        else => return value,
    };
    const shifted_mask = width_mask << shift;
    return (current & ~shifted_mask) | ((value & width_mask) << shift);
}
