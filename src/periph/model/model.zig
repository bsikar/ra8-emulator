//! Pluggable device models (RA8EMU-210): where a model attaches, the
//! catalog that makes one, and the parts it knows.
pub const endpoint = @import("endpoint.zig");
pub const catalog = @import("catalog.zig");
pub const parts = @import("parts.zig");
