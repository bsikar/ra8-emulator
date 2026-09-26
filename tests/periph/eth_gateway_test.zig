//! GWCA and COMA: the two handshakes the bring-up polls, and the mode
//! machine the gateway is held to.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.periph.eth_regs;
const gateway = ra8.periph.eth_gateway;

test "GWMS reports the gateway's mode" {
    var agent = gateway.Gateway{};
    for ([_]u32{ 1, 2, 3 }) |code| agent.modeWrite(regs.cluster.gwca0 + regs.gwca.gwmc, 4, code);
    try std.testing.expectEqual(@as(u32, 3), agent.modeRead(regs.cluster.gwca0 + regs.gwca.gwms, 4));
    try std.testing.expect(agent.mode.operational());
}

test "a gateway commanded straight to operation stays in reset" {
    var agent = gateway.Gateway{};
    agent.modeWrite(regs.cluster.gwca0 + regs.gwca.gwmc, 4, 3);
    try std.testing.expectEqual(@as(u32, 0), agent.modeRead(regs.cluster.gwca0 + regs.gwca.gwms, 4));
    try std.testing.expectEqual(@as(u32, 1), agent.mode.refused);
}

test "GWMS is the machine's to report" {
    var agent = gateway.Gateway{};
    agent.modeWrite(regs.cluster.gwca0 + regs.gwca.gwms, 4, 3);
    try std.testing.expectEqual(@as(u32, 0), agent.mode.commands);
}

test "the AXI init answers the request it was given" {
    var agent = gateway.Gateway{};
    const at = regs.cluster.gwca0 + regs.gwca.gwarirm;
    try std.testing.expectEqual(@as(u32, 0), agent.arirmRead(at, 4) & regs.gwca.arr);
    agent.arirmWrite(at, 4, regs.gwca.ariog);
    try std.testing.expect(agent.arirmRead(at, 4) & regs.gwca.arr != 0);
    try std.testing.expectEqual(@as(u32, 1), agent.inits);
}

test "holding ARIOG does not count a second init" {
    var agent = gateway.Gateway{};
    const at = regs.cluster.gwca0 + regs.gwca.gwarirm;
    agent.arirmWrite(at, 4, regs.gwca.ariog);
    agent.arirmWrite(at, 4, regs.gwca.ariog);
    try std.testing.expectEqual(@as(u32, 1), agent.inits);
}

test "the buffer pool answers its own request" {
    var pool = gateway.Pool{};
    const at = regs.cluster.coma + regs.coma.cabpirm;
    try std.testing.expectEqual(@as(u32, 0), pool.read(at, 4));
    pool.write(at, 4, regs.coma.bpiog);
    try std.testing.expect(pool.read(at, 4) & regs.coma.bpr != 0);
    try std.testing.expectEqual(@as(u32, 1), pool.inits);
}

test "a pool that was never asked reports no init done" {
    var pool = gateway.Pool{};
    const at = regs.cluster.coma + regs.coma.cabpirm;
    pool.write(at, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), pool.read(at, 4) & regs.coma.bpr);
    try std.testing.expect(pool.quiet());
}

test "an agent nothing touched is quiet" {
    const agent = gateway.Gateway{};
    try std.testing.expect(agent.quiet());
}
