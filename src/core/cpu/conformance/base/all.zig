//! Conformance vectors for the base instruction groups of the decode table,
//! one file per group, named after the group (RA8EMU-278, 279, 280).
pub const shift_imm_vectors = @import("shift_imm_vectors.zig");

/// The group named by every base vector, for the coverage table.
pub const covered: []const []const u8 = &(shift_imm_vectors.covered);
