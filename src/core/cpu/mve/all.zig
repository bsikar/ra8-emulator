//! The M85 MVE (Helium) semantics, one namespace so root.zig carries a
//! single line for them: pure functions over Q registers and VPR, with
//! their vectors (RA8EMU-25, RA8EMU-23).
pub const qreg = @import("qreg.zig");
pub const predicate = @import("predicate.zig");
pub const int = @import("int.zig");
pub const int_vectors = @import("int_vectors.zig");
pub const int_shift = @import("int_shift.zig");
pub const int_shift_vectors = @import("int_shift_vectors.zig");
pub const int_width = @import("int_width.zig");
pub const int_width_vectors = @import("int_width_vectors.zig");
pub const int_insert = @import("int_insert.zig");
pub const int_insert_vectors = @import("int_insert_vectors.zig");
pub const reduce = @import("reduce.zig");
pub const reduce_vectors = @import("reduce_vectors.zig");
