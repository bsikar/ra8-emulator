//! One R-Switch port: the ETHA agent's mode machine and the RMAC's MDIO
//! window onto the PHY behind it.
//!
//! A port is two register windows a thousand bytes apart, so it hands the bus
//! two blocks rather than claiming the gap between them. Everything else in
//! the port's two kilobytes is configuration the driver writes and reads back,
//! which the bus already does for an address nothing models.
//!
//! Every register here is 32 bits, so an access narrower than a word is the
//! `lanes.zig` rule: a read is served from the word the address lands in and
//! then cut, and a store is merged into that word so the lanes it does not
//! name keep what they had.
const std = @import("std");
const lanes = @import("lanes.zig");
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
        const offset = address -% self.etha_base;
        const whole: u32 = switch (lanes.word(offset)) {
            regs.etha.eamc, regs.etha.eams => self.mode.status(),
            else => 0,
        };
        return lanes.part(whole, lanes.lane(offset), width);
    }

    pub fn ethaWrite(self: *Port, address: u32, width: u3, value: u32) void {
        const offset = address -% self.etha_base;
        // EAMS is the machine's own to report. A store there moves nothing.
        if (lanes.word(offset) != regs.etha.eamc) return;
        const at = lanes.lane(offset);
        // OPC is the bottom of the word, so a store that reaches none of its
        // lanes carries no command however wide the rest of it is.
        if (lanes.named(at, width) & regs.etha.opc_mask == 0) return;
        const asked = lanes.merge(self.mode.status(), at, width, value);
        self.mode.command(asked & regs.etha.opc_mask);
    }

    pub fn rmacRead(self: *Port, address: u32, width: u3) u32 {
        const offset = address -% self.rmac_base;
        if (lanes.word(offset) != regs.rmac.mpsm) return 0;
        return lanes.part(self.mpsm, lanes.lane(offset), width);
    }

    /// PRD is the top half of MPSM and the control fields are the bottom, so
    /// a driver that builds a frame in two halfword stores only has a whole
    /// frame once the second one lands. The merge is what makes the order of
    /// those two stores stop mattering, and PSME in the merged word is what
    /// decides whether anything goes out on the wire.
    pub fn rmacWrite(self: *Port, address: u32, width: u3, value: u32) void {
        const offset = address -% self.rmac_base;
        if (lanes.word(offset) != regs.rmac.mpsm) return;
        const asked = lanes.merge(self.mpsm, lanes.lane(offset), width, value);
        if (asked & regs.rmac.psme == 0) {
            // No frame asked for: the register just holds what was written.
            self.mpsm = asked;
            return;
        }
        self.mpsm = self.phy.transact(asked);
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
