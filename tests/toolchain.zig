//! The host policy and public CLI contract for the toolchain feature.
test {
    _ = @import("host/toolchain/artifact_test.zig");
    _ = @import("host/toolchain/target_test.zig");
    _ = @import("host/toolchain/plan_test.zig");
    _ = @import("interfaces/cli/toolchain_test.zig");
}
