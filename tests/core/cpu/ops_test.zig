//! Covers src/core/cpu/ops.zig: pulls in the test file for every instruction
//! group under src/core/cpu/ops/, so tests/all.zig carries one line for
//! all of them.

test {
    _ = @import("ops/hint_test.zig");
    _ = @import("ops/ldr_literal_test.zig");
    _ = @import("ops/ldst_imm_test.zig");
    _ = @import("ops/ldst_reg_test.zig");
    _ = @import("ops/ldm_stm_test.zig");
    _ = @import("ops/ldrd_strd_test.zig");
    _ = @import("ops/ldm_stm_wide_test.zig");
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
    _ = @import("ops/shift_reg_test.zig");
    _ = @import("ops/add_sub_wide_test.zig");
    _ = @import("ops/long_mul_test.zig");
    _ = @import("ops/mrs_msr_test.zig");
    _ = @import("ops/ldst_reg_wide_test.zig");
    _ = @import("ops/bitfield_test.zig");
    _ = @import("ops/mul_acc_test.zig");
    _ = @import("ops/saturate_test.zig");
    _ = @import("ops/misc_wide_test.zig");
    _ = @import("ops/extend_wide_test.zig");
    _ = @import("ops/pkh_test.zig");
    _ = @import("ops/parallel_test.zig");
    _ = @import("ops/sel_test.zig");
    _ = @import("ops/sat_arith_test.zig");
    _ = @import("ops/extend_b16_test.zig");
    _ = @import("ops/sat16_test.zig");
    _ = @import("ops/usad8_test.zig");
    _ = @import("ops/umaal_test.zig");
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
    _ = @import("ops/fp_arith_test.zig");
    _ = @import("ops/fp_unary_test.zig");
    _ = @import("ops/fp_regs_test.zig");
    _ = @import("ops/fp_system_test.zig");
    _ = @import("ops/fp_convert_test.zig");
    _ = @import("ops/fp_directed_test.zig");
    _ = @import("ops/fp_move_test.zig");
    _ = @import("ops/fp_mem_test.zig");
    _ = @import("ops/table_test.zig");
}
