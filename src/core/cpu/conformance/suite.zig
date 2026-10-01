//! The conformance suite: every encoding the Zig core's semantics claim, and
//! the encoding of every vector that covers one. Each semantics module
//! (src/core/cpu/fpu/, src/core/cpu/mve/ and the rest) exports a `claimed`
//! list and a `covered` list, and joins them here with `++`, so the coverage
//! table and the missing-vector check see the whole core at once.
//!
//! Empty until the first semantics module lands; the checks over it still run,
//! so the first claim without a vector fails the build.
pub const claimed: []const []const u8 = &.{};

pub const covered: []const []const u8 = &.{};
