//! Bundle runner for host history move tests.
test {
    _ = @import("move_test.zig");
    _ = @import("windows_test.zig");
    _ = @import("file_test.zig");
    _ = @import("tree_test.zig");
    _ = @import("probe_test.zig");
    _ = @import("receipt_test.zig");
    _ = @import("wire_test.zig");
    _ = @import("deadline_test.zig");
    _ = @import("verify_test.zig");
    _ = @import("window_test.zig");
    _ = @import("collector_test.zig");
    _ = @import("proxy_test.zig");
    _ = @import("provider_test.zig");
    _ = @import("context_test.zig");
    _ = @import("intent_test.zig");
    _ = @import("bridge_test.zig");
    _ = @import("recovery_test.zig");
    _ = @import("dispatch_test.zig");
    _ = @import("linux_test.zig");
}
