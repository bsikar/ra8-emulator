//! The conformance suite: every encoding the Zig core's semantics claim, and
//! the encoding of every vector that covers one. Each semantics module
//! (src/core/cpu/fpu/, src/core/cpu/mve/ and the rest) exports a `claimed`
//! list and a `covered` list, and joins them here with `++`, so the coverage
//! table and the missing-vector check see the whole core at once.

/// Where the generated coverage table lives, relative to the build root.
pub const table_path = "docs/conformance.md";

const fpu_sign = @import("../fpu/sign_vectors.zig");

pub const claimed: []const []const u8 = &fpu_sign.claimed;

pub const covered: []const []const u8 = &fpu_sign.covered;
