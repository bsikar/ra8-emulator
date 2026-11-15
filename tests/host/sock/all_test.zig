//! Bundle runner for host socket unit tests.
//! Keeps tests/all_host.zig under the 400-line gate limit.
const std = @import("std");

test {
    _ = @import("sock_test.zig");
    _ = @import("windows_test.zig");
    _ = @import("ready_test.zig");
    _ = @import("afd_test.zig");
    _ = @import("path_test.zig");
    _ = @import("unix_test.zig");
}
