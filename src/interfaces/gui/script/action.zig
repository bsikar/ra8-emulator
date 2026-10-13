//! Action definitions for GUI automation scripting (RA8EMU-1120).
//! Defines the parsed actions, timing specifications, and named UI targets.
const std = @import("std");

pub const TimeSpec = union(enum) {
    time_ns: u64,
    frame: u32,

    pub fn matches(self: TimeSpec, elapsed_ns: u64, frame_idx: u32) bool {
        return switch (self) {
            .time_ns => |ns| elapsed_ns >= ns,
            .frame => |f| frame_idx >= f,
        };
    }
};

pub const NamedTarget = enum {
    bar_run,
    bar_pause,
    bar_step,
    bar_speed,
    camera_allow_once,
    camera_always,
    camera_cam,
    camera_grd,
    board_sw1,
    board_sw2,
};

pub const Target = union(enum) {
    coord: struct { x: i32, y: i32 },
    named: NamedTarget,
    touch: struct { x: u16, y: u16 },
};

pub const Drag = struct {
    from_x: i32,
    from_y: i32,
    to_x: i32,
    to_y: i32,
    duration_ms: u32,
};

pub const Action = union(enum) {
    click: Target,
    drag: Drag,
    type_text: []const u8,
    key: struct { code: u8 },
    quit,
};

pub const Item = struct {
    at: TimeSpec,
    action: Action,
    executed: bool = false,
};
