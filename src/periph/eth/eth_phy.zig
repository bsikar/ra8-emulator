//! The Ethernet PHY on the MDIO bus, and the management frame RMAC.MPSM
//! carries to it.
//!
//! The PHY is a part on a two-wire bus like any other: it answers at its own
//! address and nowhere else, and the registers it measures are its to write.
//! dev did neither. It never read MPSM.PDA at all, so a read addressed to a
//! PHY that is not on the board came back with this one's registers; and its
//! register write took a value anywhere in the file, so a driver could store
//! into BMSR and read back a link that never negotiated. Both are refused
//! here and counted.
const std = @import("std");
const regs = @import("eth_regs.zig");

/// Where the board's PHY answers. One PHY, at the bottom of the address
/// space, which is what the bring-up code reads.
pub const address: u32 = 0;

pub const reg = struct {
    pub const bmcr: u32 = 0;
    pub const bmsr: u32 = 1;
    pub const id_high: u32 = 2;
    pub const id_low: u32 = 3;
    pub const anar: u32 = 4;
    pub const anlpar: u32 = 5;
    pub const count: u32 = 32;
};

/// A PHY that has auto-negotiated 100BASE-TX full duplex, which is what the
/// peer on the other end of this board's wire is. The identity registers are
/// left at zero: this tree does not model a particular vendor's part, and a
/// made-up OUI would read like silicon it is not.
pub const seed = struct {
    pub const bmcr: u16 = 0x3100;
    pub const bmsr: u16 = 0x782D;
    pub const anar: u16 = 0x01E1;
    pub const anlpar: u16 = 0x01E1;
};

/// BMCR bits that ask for something and clear themselves once it is done.
pub const bmcr = struct {
    pub const reset: u16 = 0x8000;
    pub const restart_an: u16 = 0x0200;
};

/// What an idle MDIO bus reads as: nobody drives it low, so it floats high.
pub const idle_data: u16 = 0xFFFF;

/// The registers the PHY measures or identifies itself with. A management
/// write to one of these moves nothing on real silicon.
pub fn readOnly(index: u32) bool {
    return index == reg.bmsr or index == reg.id_high or
        index == reg.id_low or index == reg.anlpar;
}

pub const Phy = struct {
    file: [reg.count]u16 = .{0} ** reg.count,
    /// Management frames carried out, each way.
    reads: u32 = 0,
    writes: u32 = 0,
    /// BMCR.RESET commands performed.
    resets: u32 = 0,
    /// Writes refused because the PHY owns the register.
    read_only: u32 = 0,
    /// Frames addressed to a PHY this board does not have.
    no_phy: u32 = 0,
    /// Clause-45 frames, which this PHY does not speak.
    unsupported: u32 = 0,
    /// Frames whose operation is not a Clause-22 read or write.
    bad_op: u32 = 0,

    pub fn init() Phy {
        var self = Phy{};
        self.seedFile();
        return self;
    }

    fn seedFile(self: *Phy) void {
        self.file = .{0} ** reg.count;
        self.file[reg.bmcr] = seed.bmcr;
        self.file[reg.bmsr] = seed.bmsr;
        self.file[reg.anar] = seed.anar;
        self.file[reg.anlpar] = seed.anlpar;
    }

    pub fn value(self: *const Phy, index: u32) u16 {
        if (index >= reg.count) return 0;
        return self.file[index];
    }

    /// A management write. The PHY's own registers are refused; BMCR's
    /// request bits are carried out rather than stored.
    pub fn store(self: *Phy, index: u32, data: u16) void {
        if (index >= reg.count) return;
        if (readOnly(index)) {
            self.read_only += 1;
            return;
        }
        if (index != reg.bmcr) {
            self.file[index] = data;
            return;
        }
        if (data & bmcr.reset != 0) {
            self.resets += 1;
            self.seedFile();
            return;
        }
        self.file[reg.bmcr] = data & ~bmcr.restart_an;
    }

    /// One MPSM management frame. Returns what MPSM reads back afterwards:
    /// PSME has cleared, and a read has put the PHY's answer in the data
    /// field.
    pub fn transact(self: *Phy, mpsm: u32) u32 {
        const done = mpsm & ~regs.rmac.psme;
        if (mpsm & regs.rmac.mff != 0) {
            self.unsupported += 1;
            return regs.withData(done, 0);
        }
        const target = (mpsm >> regs.rmac.pda_shift) & regs.rmac.pda_mask;
        if (target != address) {
            self.no_phy += 1;
            return regs.withData(done, idle_data);
        }
        const index = (mpsm >> regs.rmac.pra_shift) & regs.rmac.pra_mask;
        const op: regs.Op = @enumFromInt(@as(u2, @truncate((mpsm >> regs.rmac.pop_shift))));
        switch (op) {
            .read => {
                self.reads += 1;
                return regs.withData(done, self.value(index));
            },
            .write => {
                self.writes += 1;
                self.store(index, regs.dataOf(mpsm));
                return done;
            },
            else => {
                self.bad_op += 1;
                return regs.withData(done, 0);
            },
        }
    }

    pub fn refused(self: *const Phy) u32 {
        return self.read_only + self.no_phy + self.unsupported + self.bad_op;
    }

    pub fn quiet(self: *const Phy) bool {
        return self.reads == 0 and self.writes == 0 and self.refused() == 0;
    }
};
