//! Covers src/core/cpu/ops.zig: pulls in the test file for every instruction
//! group under src/core/cpu/ops/, so tests/all.zig carries one line for
//! all of them.

test {
    _ = @import("ops/hint_test.zig");
    _ = @import("ops/ldr_literal_test.zig");
    _ = @import("ops/ldst_imm_test.zig");
    _ = @import("ops/ldst_reg_test.zig");
    _ = @import("ops/ldm_stm_test.zig");
    _ = @import("ops/ldst_wide_test.zig");
    _ = @import("ops/shift_imm_test.zig");
    _ = @import("ops/add_sub_test.zig");
    _ = @import("ops/dp_reg_test.zig");
    _ = @import("ops/special_data_test.zig");
    _ = @import("ops/barrier_test.zig");
    _ = @import("ops/branch_test.zig");
    _ = @import("ops/mov_wide_test.zig");
    _ = @import("ops/divide_test.zig");
    _ = @import("ops/dp_shifted_test.zig");
    _ = @import("ops/imm_fields_test.zig");
    _ = @import("ops/imm_logic_test.zig");
    _ = @import("ops/imm_arith_test.zig");
    _ = @import("ops/branch_wide_test.zig");
    _ = @import("ops/cps_test.zig");
    _ = @import("ops/cbz_test.zig");
    _ = @import("ops/extend_test.zig");
    _ = @import("ops/reverse_test.zig");
    _ = @import("ops/it_test.zig");
    _ = @import("it_state_test.zig");
    _ = @import("ops/push_pop_test.zig");
    _ = @import("ops/sp_arith_test.zig");
    _ = @import("ops/table_test.zig");
}
