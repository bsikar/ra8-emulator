//! The conformance suite: every encoding the Zig core's semantics claim, and
//! the encoding of every vector that covers one. Each semantics module
//! (src/core/cpu/fpu/, src/core/cpu/mve/ and the rest) exports a `claimed`
//! list and a `covered` list, and joins them here with `++`, so the coverage
//! table and the missing-vector check see the whole core at once.

/// Where the generated coverage table lives, relative to the build root.
pub const table_path = "docs/conformance.md";

const fpu_sign = @import("../fpu/sign_vectors.zig");
const fpu_add = @import("../fpu/add_vectors.zig");
const fpu_mul = @import("../fpu/mul_vectors.zig");
const fpu_mac = @import("../fpu/mac_vectors.zig");
const fpu_fma = @import("../fpu/fma_vectors.zig");
const fpu_div = @import("../fpu/div_vectors.zig");
const fpu_sqrt = @import("../fpu/sqrt_vectors.zig");
const fpu_compare = @import("../fpu/compare_vectors.zig");
const fpu_convert = @import("../fpu/convert_vectors.zig");
const fpu_int = @import("../fpu/int_vectors.zig");
const fpu_directed = @import("../fpu/directed_vectors.zig");
const fpu_rint = @import("../fpu/rint_vectors.zig");
const fpu_minmax = @import("../fpu/minmax_vectors.zig");
const fpu_select = @import("../fpu/select_vectors.zig");
const fpu_fixed = @import("../fpu/fixed_vectors.zig");
const fpu_half = @import("../fpu/half_vectors.zig");
const fpu_move = @import("../fpu/move_vectors.zig");
const fpu_transfer = @import("../fpu/transfer_vectors.zig");
const mve_int = @import("../mve/int_vectors.zig");
const mve_shift = @import("../mve/int_shift_vectors.zig");
const mve_width = @import("../mve/int_width_vectors.zig");
const mve_insert = @import("../mve/int_insert_vectors.zig");
const mve_reduce = @import("../mve/reduce_vectors.zig");
const mve_mul = @import("../mve/int_mul_vectors.zig");
const mve_compare = @import("../mve/compare_vectors.zig");
const mve_minmax = @import("../mve/reduce_minmax_vectors.zig");
const mve_brsr = @import("../mve/bit_reverse_vectors.zig");
const mve_vldr = @import("../mve/contiguous_vectors.zig");
const mve_vldr_wide = @import("../mve/contiguous_wide_vectors.zig");
const mve_gather = @import("../mve/gather_vectors.zig");
const mve_gather64 = @import("../mve/gather64_vectors.zig");
const mve_gather_imm = @import("../mve/gather_imm_vectors.zig");
const mve_interleave = @import("../mve/interleave_vectors.zig");
const mve_float = @import("../mve/float_vectors.zig");
const mve_float_fma = @import("../mve/float_fma_vectors.zig");
const mve_float_abs = @import("../mve/float_abs_vectors.zig");
const mve_float_cmp = @import("../mve/float_cmp_vectors.zig");
const mve_float_cvt = @import("../mve/float_cvt_vectors.zig");
const mve_float_int = @import("../mve/float_int_vectors.zig");
const mve_float_rint = @import("../mve/float_rint_vectors.zig");
const mve_float_minmax = @import("../mve/float_minmax_vectors.zig");
const mve_float_minmaxv = @import("../mve/float_minmaxv_vectors.zig");
const mve_float_complex = @import("../mve/float_complex_vectors.zig");

pub const claimed: []const []const u8 = &(fpu_sign.claimed ++ fpu_add.claimed ++ fpu_mul.claimed ++ fpu_mac.claimed ++ fpu_fma.claimed ++ fpu_div.claimed ++ fpu_sqrt.claimed ++ fpu_compare.claimed ++ fpu_convert.claimed ++ fpu_int.claimed ++ fpu_directed.claimed ++ fpu_rint.claimed ++ fpu_minmax.claimed ++ fpu_select.claimed ++ fpu_fixed.claimed ++ fpu_half.claimed ++ fpu_move.claimed ++ fpu_transfer.claimed ++ mve_int.claimed ++ mve_shift.claimed ++ mve_width.claimed ++ mve_insert.claimed ++ mve_reduce.claimed ++ mve_mul.claimed ++ mve_compare.claimed ++ mve_minmax.claimed ++ mve_brsr.claimed ++ mve_vldr.claimed ++ mve_vldr_wide.claimed ++ mve_gather.claimed ++ mve_gather64.claimed ++ mve_gather_imm.claimed ++ mve_interleave.claimed ++ mve_float.claimed ++ mve_float_fma.claimed ++ mve_float_abs.claimed ++ mve_float_cmp.claimed ++ mve_float_cvt.claimed ++ mve_float_int.claimed ++ mve_float_rint.claimed ++ mve_float_minmax.claimed ++ mve_float_minmaxv.claimed ++ mve_float_complex.claimed);

pub const covered: []const []const u8 = &(fpu_sign.covered ++ fpu_add.covered ++ fpu_mul.covered ++ fpu_mac.covered ++ fpu_fma.covered ++ fpu_div.covered ++ fpu_sqrt.covered ++ fpu_compare.covered ++ fpu_convert.covered ++ fpu_int.covered ++ fpu_directed.covered ++ fpu_rint.covered ++ fpu_minmax.covered ++ fpu_select.covered ++ fpu_fixed.covered ++ fpu_half.covered ++ fpu_move.covered ++ fpu_transfer.covered ++ mve_int.covered ++ mve_shift.covered ++ mve_width.covered ++ mve_insert.covered ++ mve_reduce.covered ++ mve_mul.covered ++ mve_compare.covered ++ mve_minmax.covered ++ mve_brsr.covered ++ mve_vldr.covered ++ mve_vldr_wide.covered ++ mve_gather.covered ++ mve_gather64.covered ++ mve_gather_imm.covered ++ mve_interleave.covered ++ mve_float.covered ++ mve_float_fma.covered ++ mve_float_abs.covered ++ mve_float_cmp.covered ++ mve_float_cvt.covered ++ mve_float_int.covered ++ mve_float_rint.covered ++ mve_float_minmax.covered ++ mve_float_minmaxv.covered ++ mve_float_complex.covered);
