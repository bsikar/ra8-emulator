//! The NPU share of the test root: every test file under tests/chip/periph/npu/,
//! pulled in by tests/all.zig.
test {
    _ = @import("npu_cmd_test.zig");
    _ = @import("npu_test.zig");
    _ = @import("npu_vela_test.zig");
    _ = @import("npu_vela_regs_test.zig");
    _ = @import("npu_vela_dma_test.zig");
    _ = @import("npu_vela_run_test.zig");
    _ = @import("npu_vela_hook_test.zig");
    _ = @import("npu_vela_fm_test.zig");
    _ = @import("npu_vela_quant_test.zig");
    _ = @import("npu_vela_addr_test.zig");
    _ = @import("npu_vela_bias_test.zig");
    _ = @import("npu_vela_weights_test.zig");
    _ = @import("npu_vela_order_test.zig");
    _ = @import("npu_vela_round_test.zig");
    _ = @import("npu_vela_conv_test.zig");
    _ = @import("npu_vela_convop_test.zig");
    _ = @import("npu_vela_mul_test.zig");
    _ = @import("npu_vela_addsub_test.zig");
    _ = @import("npu_vela_avgpool_test.zig");
    _ = @import("npu_vela_minmax_test.zig");
    _ = @import("npu_vela_pool_test.zig");
}
