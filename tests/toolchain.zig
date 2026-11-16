//! The host policy and public CLI contract for the toolchain feature.
test {
    _ = @import("host/toolchain/archive_test.zig");
    _ = @import("host/toolchain/ownership_test.zig");
    _ = @import("host/toolchain/paths_test.zig");
    _ = @import("host/toolchain/artifact_test.zig");
    _ = @import("host/toolchain/tree_test.zig");
    _ = @import("host/toolchain/digest_test.zig");
    _ = @import("host/toolchain/provision_test.zig");
    _ = @import("host/toolchain/target_test.zig");
    _ = @import("host/toolchain/plan_test.zig");
    _ = @import("interfaces/cli/toolchain_test.zig");
}
