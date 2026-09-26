//! One R-Switch port: the ETHA agent's mode machine and the RMAC's MDIO
//! window onto the PHY behind it.
//!
//! A port is two register windows a thousand bytes apart, so it hands the bus
//! two blocks rather than claiming the gap between them. Everything else in
//! the port's two kilobytes is configuration the driver writes and reads back,
//! which the bus already does for an address nothing models.
const std = @import("std");
const periph = @import("registry.zig");
const regs = @import("eth_regs.zig");
const eth_mode = @import("eth_mode.zig");
const eth_phy = @import("eth_phy.zig");

pub const Port = struct {
    /// Where this port's two agents answer. A board fact, so it is set when
    /// the board populates the port.
    etha_base: u32,
    rmac_base: u32,
    mode: eth_mode.Machine = .{},
    phy: eth_phy.Phy = eth_phy.Phy.init(),
    /// The last management frame, as MPSM reads back.
    mpsm: u32 = 0,

    pub fn init(etha_base: u32, rmac_base: u32) Port {
        return .{ .etha_base = etha_base, .rmac_base = rmac_base };
    }

    /// EAMC reads back the command; EAMS reports where the machine is.
    pub fn ethaRead(self: *Port, address: u32, width: u3) u32 {
        _ = width;
        return switch (address -% self.etha_base) {
            regs.etha.eamc => self.mode.status(),
            regs.etha.eams => self.mode.status(),
            else => 0,
        };
    }

    pub fn ethaWrite(self: *Port, address: u32, width: u3, value: u32) void {
        _ = width;
        // EAMS is the machine's own to report. A store there moves nothing.
        if (address -% self.etha_base != regs.etha.eamc) return;
        self.mode.command(value & regs.etha.opc_mask);
    }

    pub fn rmacRead(self: *Port, address: u32, width: u3) u32 {
        _ = width;
        if (address -% self.rmac_base != regs.rmac.mpsm) return 0;
        return self.mpsm;
    }

    pub fn rmacWrite(self: *Port, address: u32, width: u3, value: u32) void {
        _ = width;
        if (address -% self.rmac_base != regs.rmac.mpsm) return;
        if (value & regs.rmac.psme == 0) {
            // No frame asked for: the register just holds what was written.
            self.mpsm = value;
            return;
        }
        self.mpsm = self.phy.transact(value);
    }

    pub fn quiet(self: *const Port) bool {
        return self.mode.quiet() and self.phy.quiet();
    }

    pub fn ethaBlock(self: *Port) periph.Block {
        return .{
            .name = "ETHA",
            .base = self.etha_base,
            .size = regs.etha.mode_span,
            .context = self,
            .readFn = ethaReadThunk,
            .writeFn = ethaWriteThunk,
        };
    }

    pub fn rmacBlock(self: *Port) periph.Block {
        return .{
            .name = "RMAC",
            .base = self.rmac_base,
            .size = regs.rmac.mpsm_span,
            .context = self,
            .readFn = rmacReadThunk,
            .writeFn = rmacWriteThunk,
        };
    }
};

fn ethaReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Port = @ptrCast(@alignCast(context));
    return self.ethaRead(address, width);
}

fn ethaWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Port = @ptrCast(@alignCast(context));
    self.ethaWrite(address, width, value);
}

fn rmacReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Port = @ptrCast(@alignCast(context));
    return self.rmacRead(address, width);
}

fn rmacWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Port = @ptrCast(@alignCast(context));
    self.rmacWrite(address, width, value);
}
