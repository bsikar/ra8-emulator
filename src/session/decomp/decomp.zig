//! Static function CFG reconstruction, dataflow, and pseudocode-lite pipeline (ADR 0011, RA8EMU-1353..1355).
pub const aapcs = @import("aapcs.zig");
pub const builder = @import("builder.zig");
pub const cache = @import("cache.zig");
pub const cfg = @import("cfg.zig");
pub const dataflow = @import("dataflow.zig");
pub const dataflow_plan = @import("dataflow_plan.zig");
pub const effect_types = @import("effect_types.zig");
pub const effects = @import("effects.zig");
pub const effects_mem = @import("effects_mem.zig");
pub const effects_wide = @import("effects_wide.zig");
pub const emit = @import("emit.zig");
pub const emit_expr = @import("emit_expr.zig");
pub const emit_format = @import("emit_format.zig");
pub const extents = @import("extents.zig");
pub const image_bus = @import("image_bus.zig");
pub const value = @import("value.zig");
