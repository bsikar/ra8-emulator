//! The board's Ethernet side: the R-Switch cluster as this board populates
//! it, two ports and the two shared agents.
//!
//! Which ports exist and where their PHYs answer is a board fact, so the
//! wiring lives here rather than in the port model.
const engine = @import("../core/engine.zig");
const eth = @import("../periph/eth/eth.zig");
const eth_queue = @import("../periph/eth/eth_queue.zig");
const gateway = @import("../periph/eth/eth_gateway.zig");
const pdctr = @import("../periph/pdctr.zig");
const periph = @import("../periph/registry.zig");
const regs = @import("../periph/eth/eth_regs.zig");

pub const Rswitch = struct {
    ports: [regs.cluster.port_count]eth.Port = .{
        eth.Port.init(regs.cluster.etha0, regs.cluster.rmac0),
        eth.Port.init(regs.cluster.etha1, regs.cluster.rmac1),
    },
    /// Each port's queue depth and error-interrupt words.
    agents: [regs.cluster.port_count]eth.agent.Agent = .{
        eth.agent.Agent.init(regs.cluster.etha0),
        eth.agent.Agent.init(regs.cluster.etha1),
    },
    /// The forwarding engine's control and per-port words.
    forward: eth.forward.Forward = .{},
    /// COMA's reset and clock-enable words.
    coma: eth.coma.Coma = .{},
    gateway: gateway.Gateway = .{},
    pool: gateway.Pool = .{},
    /// The gateway's descriptor side: the rings in RAM and the frames that
    /// move through them.
    queues: eth_queue.Queues = .{},

    /// Put every window the cluster answers for on the bus. The blocks hold
    /// pointers into this struct, so this runs once the board has stopped
    /// moving, and the ESWM power domain is wired to each port here for the
    /// same reason.
    pub fn attach(
        self: *Rswitch,
        bus: *periph.Bus,
        memory: engine.Engine,
        domain: *const pdctr.Pdctr,
    ) periph.Error!void {
        for (&self.ports) |*port| {
            // The whole cluster sits in the ESWM power domain, so every port
            // asks the same one before it answers.
            port.domain = domain;
            try bus.add(port.ethaBlock());
            try bus.add(port.rmacBlock());
            try bus.add(port.macBlock());
        }
        for (&self.agents) |*agent| {
            for (agent.blocks()) |block| try bus.add(block);
        }
        for (self.forward.blocks()) |block| try bus.add(block);
        try bus.add(self.coma.block());
        try bus.add(self.gateway.modeBlock());
        try bus.add(self.gateway.arirmBlock());
        try bus.add(self.pool.block());
        self.queues.mode = &self.gateway.mode;
        self.queues.rings.memory = memory;
        try bus.add(self.queues.baseBlock());
        try bus.add(self.queues.requestBlock());
        try bus.add(self.queues.configBlock());
    }

    /// The chunk boundary: the rings take in whatever the far end has for
    /// them, once the gateway is running.
    pub fn tick(self: *Rswitch) void {
        self.queues.tick();
    }

    pub fn quiet(self: *const Rswitch) bool {
        for (&self.ports) |*port| {
            if (!port.quiet()) return false;
        }
        for (&self.agents) |*agent| {
            if (!agent.quiet()) return false;
        }
        if (!self.coma.quiet()) return false;
        return self.forward.quiet() and self.gateway.quiet() and self.pool.quiet() and self.queues.quiet();
    }
};
