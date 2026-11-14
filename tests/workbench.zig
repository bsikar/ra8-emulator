//! Host workbench policy and project lifecycle tests share the host suite.
test {
    _ = @import("toolchain.zig");
    _ = @import("host/project/config_test.zig");
    _ = @import("host/project/files_test.zig");
    _ = @import("host/project/handoff_test.zig");
    _ = @import("host/project/receipt_test.zig");
    _ = @import("host/project/map_test.zig");
    _ = @import("host/project/project_test.zig");
    _ = @import("host/project/sources_test.zig");
    _ = @import("interfaces/rpc/project_test.zig");
    _ = @import("interfaces/rpc/session/connection_test.zig");
    _ = @import("interfaces/cli/project/owner_test.zig");
}
