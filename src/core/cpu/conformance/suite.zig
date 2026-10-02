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

pub const claimed: []const []const u8 = &(fpu_sign.claimed ++ fpu_add.claimed ++ fpu_mul.claimed ++ fpu_mac.claimed ++ fpu_fma.claimed ++ fpu_div.claimed ++ fpu_sqrt.claimed ++ fpu_compare.claimed ++ fpu_convert.claimed ++ fpu_int.claimed ++ fpu_directed.claimed ++ fpu_rint.claimed ++ fpu_minmax.claimed ++ fpu_select.claimed ++ fpu_fixed.claimed ++ fpu_half.claimed ++ fpu_move.claimed ++ fpu_transfer.claimed ++ mve_int.claimed);

pub const covered: []const []const u8 = &(fpu_sign.covered ++ fpu_add.covered ++ fpu_mul.covered ++ fpu_mac.covered ++ fpu_fma.covered ++ fpu_div.covered ++ fpu_sqrt.covered ++ fpu_compare.covered ++ fpu_convert.covered ++ fpu_int.covered ++ fpu_directed.covered ++ fpu_rint.covered ++ fpu_minmax.covered ++ fpu_select.covered ++ fpu_fixed.covered ++ fpu_half.covered ++ fpu_move.covered ++ fpu_transfer.covered ++ mve_int.covered);
