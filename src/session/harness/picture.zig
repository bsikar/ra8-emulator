//! The checkpoint picture source the harness binds: the panel as the
//! board shows it at the checkpoint, composed over copies of the display
//! state (the pure path, RA8EMU-D13), so asking for a picture raises no
//! VPOS and counts no frame. The composition runs on the session thread
//! at the closed round, so the picture is a function of the run alone,
//! never of a worker thread's timing or the tap's host-time rate cap.
const std = @import("std");
const state = @import("../board/state.zig");
const checkpoint_picture = @import("../history/checkpoint_picture.zig");
const frame_crop = @import("../history/frame_crop.zig");

/// The source over the run's files (which reach the board lazily, at
/// the first checkpoint).
pub fn source(files: *state.Files) checkpoint_picture.Source {
    return .{ .context = files, .lastScanFn = lastScan };
}

/// The gray panel at `at`, or null when the display shows nothing (off,
/// unpowered, no layer, unclocked).
fn lastScan(context: *anyopaque, allocator: std.mem.Allocator, at: checkpoint_picture.Position) anyerror!?checkpoint_picture.Decoded {
    const files: *state.Files = @ptrCast(@alignCast(context));
    const display = &files.board.display;
    const width = display.panelWidth();
    const height = display.panelHeight();
    if (width == 0 or height == 0 or width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return null;
    const count = try std.math.mul(usize, width, height);
    const input = display.compositeInputs() orelse return null;
    const argb = try allocator.alloc(u32, count);
    defer allocator.free(argb);
    switch (display.composite(input, display.domain.powered(), argb)) {
        .picture => {},
        .refused => return null,
    }
    const pixels = try allocator.alloc(u8, count);
    frame_crop.toGray(argb, pixels);
    return .{
        .position = at,
        .virtual_ns = files.board.time.base.now(),
        .width = @intCast(width),
        .height = @intCast(height),
        .pixels = pixels,
    };
}
