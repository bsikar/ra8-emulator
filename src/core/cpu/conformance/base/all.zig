//! Conformance vectors for the base instruction groups of the decode table,
//! one file per group, named after the group (RA8EMU-278, 279, 280).
pub const add_sub_vectors = @import("add_sub_vectors.zig");
pub const bkpt_vectors = @import("bkpt_vectors.zig");
pub const branch_vectors = @import("branch_vectors.zig");
pub const cbz_vectors = @import("cbz_vectors.zig");
pub const cps_vectors = @import("cps_vectors.zig");
pub const dp_reg_vectors = @import("dp_reg_vectors.zig");
pub const extend_vectors = @import("extend_vectors.zig");
pub const it_vectors = @import("it_vectors.zig");
pub const reverse_vectors = @import("reverse_vectors.zig");
pub const shift_imm_vectors = @import("shift_imm_vectors.zig");
pub const special_data_vectors = @import("special_data_vectors.zig");
pub const svc_vectors = @import("svc_vectors.zig");
pub const udf_vectors = @import("udf_vectors.zig");

/// The group named by every base vector, for the coverage table.
pub const covered: []const []const u8 = &(add_sub_vectors.covered ++ bkpt_vectors.covered ++ branch_vectors.covered ++ cbz_vectors.covered ++ cps_vectors.covered ++ dp_reg_vectors.covered ++ extend_vectors.covered ++ it_vectors.covered ++ reverse_vectors.covered ++ shift_imm_vectors.covered ++ special_data_vectors.covered ++ svc_vectors.covered ++ udf_vectors.covered);
