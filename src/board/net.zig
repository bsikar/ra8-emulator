//! The board's Ethernet side: the R-Switch cluster as this board populates
//! it, two ports and the two shared agents.
//!
//! Which ports exist and where their PHYs answer is a board fact, so the
//! wiring lives here rather than in the port model.
const eth = @import("../periph/eth.zig");
const gateway = @import("../periph/eth_gateway.zig");
const periph = @import("../periph/registry.zig");
const regs = @import("../periph/eth_regs.zig");

pub const Rswitch = struct {
    ports: [regs.cluster.port_count]eth.Port = .{
        eth.Port.init(regs.cluster.etha0, regs.cluster.rmac0),
        eth.Port.init(regs.cluster.etha1, regs.cluster.rmac1),
    },
    gateway: gateway.Gateway = .{},
    pool: gateway.Pool = .{},

    /// Put every window the cluster answers for on the bus. The blocks hold
    /// pointers into this struct, so this runs once the board has stopped
    /// moving.
    pub fn attach(self: *Rswitch, bus: *periph.Bus) periph.Error!void {
        for (&self.ports) |*port| {
            try bus.add(port.ethaBlock());
            try bus.add(port.rmacBlock());
        }
        try bus.add(self.gateway.modeBlock());
        try bus.add(self.gateway.arirmBlock());
        try bus.add(self.pool.block());
    }

    pub fn quiet(self: *const Rswitch) bool {
        for (&self.ports) |*port| {
            if (!port.quiet()) return false;
        }
        return self.gateway.quiet() and self.pool.quiet();
    }
};
