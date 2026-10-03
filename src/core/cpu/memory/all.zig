//! The Zig core's own memory (RA8EMU-480/485), one import for src/root.zig.
pub const store = @import("store.zig");
pub const memory_bus = @import("memory_bus.zig");
pub const guest = @import("guest.zig");
