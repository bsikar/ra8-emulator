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

pub const claimed: []const []const u8 = &(fpu_sign.claimed ++ fpu_add.claimed ++ fpu_mul.claimed ++ fpu_mac.claimed ++ fpu_fma.claimed ++ fpu_div.claimed ++ fpu_sqrt.claimed);

pub const covered: []const []const u8 = &(fpu_sign.covered ++ fpu_add.covered ++ fpu_mul.covered ++ fpu_mac.covered ++ fpu_fma.covered ++ fpu_div.covered ++ fpu_sqrt.covered);
