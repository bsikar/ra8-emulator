//! Covers src/core/cpu/conformance/base/all.zig.
const std = @import("std");
const ra8 = @import("ra8");

test {
    _ = @import("add_sub_vectors_test.zig");
    _ = @import("bkpt_vectors_test.zig");
    _ = @import("branch_vectors_test.zig");
    _ = @import("cbz_vectors_test.zig");
    _ = @import("cps_vectors_test.zig");
    _ = @import("dp_reg_vectors_test.zig");
    _ = @import("extend_vectors_test.zig");
    _ = @import("it_vectors_test.zig");
    _ = @import("reverse_vectors_test.zig");
    _ = @import("shift_imm_vectors_test.zig");
    _ = @import("special_data_vectors_test.zig");
    _ = @import("svc_vectors_test.zig");
    _ = @import("udf_vectors_test.zig");
    std.testing.refAllDecls(ra8.core.conformance_suite.base);
}
