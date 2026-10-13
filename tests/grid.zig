//! Focused scheduler dependency closure with the normal tests module boundary.
test {
    _ = @import("chip/core/cpu/systick_cut_test.zig");
    _ = @import("chip/core/scheduler/position_test.zig");
    _ = @import("chip/core/scheduler/scheduler_test.zig");
    _ = @import("chip/core/scheduler/stretch_test.zig");
    _ = @import("session/zig/round_test.zig");
    _ = @import("session/zig/wall_test.zig");
    _ = @import("session/zig/cut_bus_test.zig");
    _ = @import("session/zig/drive_test.zig");
    _ = @import("session/zig/boundary_test.zig");
    _ = @import("session/zig/session_test.zig");
    _ = @import("session/zig/cycles_test.zig");
    _ = @import("session/zig/monitor_test.zig");
    _ = @import("session/rtos/publish_test.zig");
    _ = @import("session/txm/publish_test.zig");
    _ = @import("session/api_test.zig");
    _ = @import("session/board/boundary_test.zig");
    _ = @import("session/board_boundary_sleep_test.zig");
    _ = @import("session/board/state_test.zig");
    _ = @import("session/board/grid_test.zig");
    _ = @import("session/harness/harness_test.zig");
    _ = @import("chip/core/cpu/count_test.zig");
    _ = @import("chip/core/cpu/boot_test.zig");
    _ = @import("board/snapshot/stretch_test.zig");
}
