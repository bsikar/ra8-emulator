//! Conformance vectors for the base instruction groups of the decode table,
//! one file per group, named after the group (RA8EMU-278, 279, 280).
pub const add_sub_vectors = @import("add_sub_vectors.zig");
pub const add_sub_wide_vectors = @import("add_sub_wide_vectors.zig");
pub const bitfield_vectors = @import("bitfield_vectors.zig");
pub const bkpt_vectors = @import("bkpt_vectors.zig");
pub const blxns_vectors = @import("blxns_vectors.zig");
pub const branch_vectors = @import("branch_vectors.zig");
pub const bxns_vectors = @import("bxns_vectors.zig");
pub const cbz_vectors = @import("cbz_vectors.zig");
pub const cps_vectors = @import("cps_vectors.zig");
pub const divide_vectors = @import("divide_vectors.zig");
pub const dp_reg_vectors = @import("dp_reg_vectors.zig");
pub const dp_shifted_vectors = @import("dp_shifted_vectors.zig");
pub const extend_vectors = @import("extend_vectors.zig");
pub const extend_wide_vectors = @import("extend_wide_vectors.zig");
pub const hint_vectors = @import("hint_vectors.zig");
pub const imm_arith_vectors = @import("imm_arith_vectors.zig");
pub const imm_logic_vectors = @import("imm_logic_vectors.zig");
pub const it_vectors = @import("it_vectors.zig");
pub const ldm_stm_vectors = @import("ldm_stm_vectors.zig");
pub const ldr_literal_vectors = @import("ldr_literal_vectors.zig");
pub const ldst_imm_vectors = @import("ldst_imm_vectors.zig");
pub const ldst_reg_vectors = @import("ldst_reg_vectors.zig");
pub const long_mul_vectors = @import("long_mul_vectors.zig");
pub const misc_wide_vectors = @import("misc_wide_vectors.zig");
pub const mov_wide_vectors = @import("mov_wide_vectors.zig");
pub const mul_acc_vectors = @import("mul_acc_vectors.zig");
pub const pkh_vectors = @import("pkh_vectors.zig");
pub const push_pop_vectors = @import("push_pop_vectors.zig");
pub const reverse_vectors = @import("reverse_vectors.zig");
pub const saturate_vectors = @import("saturate_vectors.zig");
pub const sel_vectors = @import("sel_vectors.zig");
pub const shift_imm_vectors = @import("shift_imm_vectors.zig");
pub const shift_reg_vectors = @import("shift_reg_vectors.zig");
pub const sp_arith_vectors = @import("sp_arith_vectors.zig");
pub const special_data_vectors = @import("special_data_vectors.zig");
pub const svc_vectors = @import("svc_vectors.zig");
pub const udf_vectors = @import("udf_vectors.zig");
pub const umaal_vectors = @import("umaal_vectors.zig");
pub const usad8_vectors = @import("usad8_vectors.zig");

/// The group named by every base vector, for the coverage table.
pub const covered: []const []const u8 = &(add_sub_vectors.covered ++ add_sub_wide_vectors.covered ++ bitfield_vectors.covered ++ bkpt_vectors.covered ++ blxns_vectors.covered ++ branch_vectors.covered ++ bxns_vectors.covered ++ cbz_vectors.covered ++ cps_vectors.covered ++ divide_vectors.covered ++ dp_reg_vectors.covered ++ dp_shifted_vectors.covered ++ extend_vectors.covered ++ extend_wide_vectors.covered ++ hint_vectors.covered ++ imm_arith_vectors.covered ++ imm_logic_vectors.covered ++ it_vectors.covered ++ ldm_stm_vectors.covered ++ ldr_literal_vectors.covered ++ ldst_imm_vectors.covered ++ ldst_reg_vectors.covered ++ long_mul_vectors.covered ++ misc_wide_vectors.covered ++ mov_wide_vectors.covered ++ mul_acc_vectors.covered ++ pkh_vectors.covered ++ push_pop_vectors.covered ++ reverse_vectors.covered ++ saturate_vectors.covered ++ sel_vectors.covered ++ shift_imm_vectors.covered ++ shift_reg_vectors.covered ++ sp_arith_vectors.covered ++ special_data_vectors.covered ++ svc_vectors.covered ++ udf_vectors.covered ++ umaal_vectors.covered ++ usad8_vectors.covered);
