//! Static CFG reconstruction and dataflow tests for the decompiler session layer.
test {
    _ = @import("image_bus_test.zig");
    _ = @import("extents_test.zig");
    _ = @import("cfg_test.zig");
    _ = @import("builder_test.zig");
    _ = @import("cache_test.zig");
    _ = @import("value_test.zig");
    _ = @import("aapcs_test.zig");
    _ = @import("effect_types_test.zig");
    _ = @import("effects_mem_test.zig");
    _ = @import("effects_test.zig");
    _ = @import("effects_wide_test.zig");
    _ = @import("dataflow_plan_test.zig");
    _ = @import("dataflow_test.zig");
}
