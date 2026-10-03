//! ETH peripheral test index.
test {
    _ = @import("eth_agent_test.zig");
    _ = @import("eth_desc_test.zig");
    _ = @import("eth_coma_test.zig");
    _ = @import("eth_tas_test.zig");
    _ = @import("eth_cbs_test.zig");
    _ = @import("eth_dma_test.zig");
    _ = @import("eth_forward_test.zig");
    _ = @import("eth_gateway_test.zig");
    _ = @import("eth_mac_test.zig");
    _ = @import("eth_mode_test.zig");
    _ = @import("eth_peer_test.zig");
    _ = @import("eth_phy_test.zig");
    _ = @import("eth_queue_test.zig");
    _ = @import("eth_test.zig");
}
