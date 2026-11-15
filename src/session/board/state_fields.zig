//! Inventory of saved, derived, and debugger-owned machine fields.
const BoardBoundary = @import("boundary.zig").BoardBoundary;
const chip = @import("ra8_chip");
const CycleClock = @import("../zig/cycles.zig").Clock;
const Driver = @import("../step_hook.zig").Driver;
const fields = @import("ra8_board").snapshot.run.fields;
const Machine = @import("../stop_machine.zig").Machine;
const unit_fields = @import("state.zig").unit_fields;

const Pair = chip.core.second.core.zig.run.Driver;

/// Classifies the fields this file picks by name. Second, its State and both
/// NVIC sources are written whole except for their validated skip paths.
pub fn complete() bool {
    const transient = "Execution control; a restore leaves the core halted";
    const points = "Debugger points stay with the attached debugger";
    const derived = "Derived cache invalidated after restore";
    return fields.complete(Machine, unit_fields, .{
        .{ .name = "breaks", .reason = points },           .{ .name = "watches", .reason = points },
        .{ .name = "next_id", .reason = points },          .{ .name = "mode", .reason = transient },
        .{ .name = "resumed", .reason = transient },       .{ .name = "halt_pending", .reason = transient },
        .{ .name = "target", .reason = transient },        .{ .name = "hits", .reason = transient },
        .{ .name = "hits_len", .reason = transient },      .{ .name = "hits_overflow", .reason = transient },
        .{ .name = "unit_held", .reason = transient },     .{ .name = "unit_taken", .reason = transient },
        .{ .name = "monitor_extra", .reason = transient },
    }) and fields.complete(Driver, .{"cycles"}, .{
        .{ .name = "machine", .reason = "Session wiring" }, .{ .name = "last", .reason = transient },
        .{ .name = "latch", .reason = "Session wiring" },   .{ .name = "unit_dirty", .reason = derived },
    }) and fields.complete(Pair, .{
        "second",
        "core",
        "ns_timebase",
        "store",
        "cycle_remainder",
        "last_ran",
        "turn_state",
    }, .{
        .{ .name = "wiring", .reason = "Boundary wiring" },
    }) and fields.complete(
        chip.core.scheduler.State,
        .{ "at", "stretch", "base", "lengths", "cut", "cut_pending" },
        .{},
    ) and
        fields.complete(@FieldType(Pair, "turn_state"), .{ "open", "share", "elapsed", "slots", "hz" }, .{}) and
        fields.complete(
            CycleClock,
            .{
                "count",
                "slots",
            },
            .{},
        ) and fields.complete(BoardBoundary, .{
        "timebase",
        "ns_timebase",
        "saved",
    }, .{
        .{ .name = "board", .reason = "Saved board wiring" },
        .{ .name = "core", .reason = "Saved guest store wiring" },
        .{ .name = "cpu", .reason = "Saved core wiring" },
        .{ .name = "reboot", .reason = "Saved board reboot wiring" },
        .{ .name = "selected", .reason = "Debugger view selection outside execution" },
        .{ .name = "second", .reason = "Saved second-core wiring" },
        .{ .name = "second_memory", .reason = "Saved second store wiring" },
        .{ .name = "pair", .reason = "Saved pair wiring" },
        .{ .name = "chunk", .reason = "Mark saved in session_runtime" },
        .{ .name = "cut", .reason = "Clock pointers retained; consumed cut carried by saved.cut" },
        .{ .name = "idle_skip", .reason = "Immutable root grid configuration" },
    }) and fields.complete(@FieldType(Pair, "core"), .{ "pending", "cpu" }, .{
        .{ .name = "memory", .reason = "Guest memory wiring" },    .{ .name = "board", .reason = "Board bus wiring" },
        .{ .name = "quiet", .reason = derived },                   .{ .name = "decoded", .reason = derived },
        .{ .name = "check", .reason = "Stable MPU-model wiring" }, .{ .name = "formed", .reason = derived },
    });
}
