//! Covers src/core/cpu/conformance/base/all.zig.
const std = @import("std");
const ra8 = @import("ra8");

test {
    _ = @import("add_sub_vectors_test.zig");
    _ = @import("add_sub_wide_vectors_test.zig");
    _ = @import("bitfield_vectors_test.zig");
    _ = @import("bkpt_vectors_test.zig");
    _ = @import("blxns_vectors_test.zig");
    _ = @import("branch_vectors_test.zig");
    _ = @import("bxns_vectors_test.zig");
    _ = @import("cbz_vectors_test.zig");
    _ = @import("cps_vectors_test.zig");
    _ = @import("divide_vectors_test.zig");
    _ = @import("dp_reg_vectors_test.zig");
    _ = @import("dp_shifted_vectors_test.zig");
    _ = @import("extend_vectors_test.zig");
    _ = @import("extend_wide_vectors_test.zig");
    _ = @import("hint_vectors_test.zig");
    _ = @import("imm_arith_vectors_test.zig");
    _ = @import("imm_logic_vectors_test.zig");
    _ = @import("it_vectors_test.zig");
    _ = @import("ldm_stm_vectors_test.zig");
    _ = @import("ldr_literal_vectors_test.zig");
    _ = @import("ldst_imm_vectors_test.zig");
    _ = @import("ldst_reg_vectors_test.zig");
    _ = @import("long_mul_vectors_test.zig");
    _ = @import("misc_wide_vectors_test.zig");
    _ = @import("mov_wide_vectors_test.zig");
    _ = @import("mul_acc_vectors_test.zig");
    _ = @import("pkh_vectors_test.zig");
    _ = @import("push_pop_vectors_test.zig");
    _ = @import("reverse_vectors_test.zig");
    _ = @import("saturate_vectors_test.zig");
    _ = @import("sel_vectors_test.zig");
    _ = @import("shift_imm_vectors_test.zig");
    _ = @import("shift_reg_vectors_test.zig");
    _ = @import("sp_arith_vectors_test.zig");
    _ = @import("special_data_vectors_test.zig");
    _ = @import("svc_vectors_test.zig");
    _ = @import("udf_vectors_test.zig");
    _ = @import("umaal_vectors_test.zig");
    std.testing.refAllDecls(ra8.core.conformance_suite.base);
}
