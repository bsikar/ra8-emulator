//! Aggregated unit and end-to-end tests for `ctl` subcommands.
test {
    _ = @import("branch_test.zig");
    _ = @import("write_test.zig");
    _ = @import("diff_test.zig");
    _ = @import("set_var_test.zig");
}
