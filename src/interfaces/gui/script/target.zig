//! Target coordinate resolution for named GUI controls (RA8EMU-1120).
//! Resolves UI controls (time bar, camera dialog/source, board switches/touch)
//! to window pixel coordinates across varying pane layouts.
const std = @import("std");
const action_mod = @import("action.zig");
const pane_layout = @import("../ui/pane_layout.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const time_bar = @import("../ui/time_bar.zig");
const camera_view = @import("../ui/camera_view.zig");
const shell_camera = @import("../shell/camera/camera.zig");
const board_pane = @import("../ui/board_pane.zig");
const board_touch = @import("../board/touch.zig");
const shell_board = @import("../shell/board/board.zig");
const fork_banner = @import("../ui/fork_banner.zig");
const draw_list = @import("ra8_render").draw_list;

const Rect = draw_list.Rect;
pub const Point = struct { x: i32, y: i32 };

pub const Target = action_mod.Target;
pub const NamedTarget = action_mod.NamedTarget;

const default_switches: [2][]const u8 = .{ "sw1", "sw2" };

/// Resolves a target to window coordinates (x, y). Returns null if pane not found.
pub fn resolve(
    allocator: std.mem.Allocator,
    layout: *const pane_layout.Layout,
    width: i32,
    height: i32,
    board: ?*const shell_board.Board,
    target: Target,
) ?Point {
    switch (target) {
        .coord => |c| return .{ .x = c.x, .y = c.y },
        .named => |named| return resolveNamed(allocator, layout, width, height, board, named),
        .touch => |touch| return resolveTouch(allocator, layout, width, height, board, touch.x, touch.y),
    }
}

fn resolveNamed(
    allocator: std.mem.Allocator,
    layout: *const pane_layout.Layout,
    width: i32,
    height: i32,
    board: ?*const shell_board.Board,
    named: NamedTarget,
) ?Point {
    switch (named) {
        .bar_run, .bar_pause, .bar_step, .bar_step_over, .bar_step_out, .bar_speed, .bar_seek => {
            const bar_area = shell_frame.barArea(width, height);
            const tb = time_bar.Layout.of(shell_frame.toList(bar_area));
            const rect = switch (named) {
                .bar_run => tb.run,
                .bar_pause => tb.pause,
                .bar_step => tb.step,
                .bar_step_over => tb.over,
                .bar_step_out => tb.out,
                .bar_speed => tb.field,
                // A bar too narrow for the seek field drops it; no target then.
                .bar_seek => if (tb.seek.empty()) return null else tb.seek,
                else => unreachable,
            };
            return centerOf(rect);
        },
        .bar_track => {
            return centerOf(shell_frame.toList(shell_frame.trackArea(width, height)));
        },
        .banner_confirm, .banner_cancel => {
            const bar = shell_frame.barArea(width, height);
            const banner: draw_list.Rect = .{ .x = 0, .y = bar.y - fork_banner.height, .w = width, .h = fork_banner.height };
            const rect = if (named == .banner_confirm) fork_banner.buttonConfirm(banner) else fork_banner.buttonCancel(banner);
            return centerOf(rect);
        },
        .camera_allow_once, .camera_always, .camera_cam, .camera_grd => {
            var solved = shell_frame.solve(layout, allocator, width, height) catch return null;
            defer solved.deinit(allocator);
            for (solved.panes.items) |placed| {
                const pane = layout.pane(placed.index) orelse continue;
                if (pane.kind != .camera) continue;
                const body = shell_frame.bodyOf(placed.area);
                const cam_layout = shell_camera.layoutIn(body);
                const rect = switch (named) {
                    .camera_allow_once => cam_layout.dialog(.allow_once),
                    .camera_always => cam_layout.dialog(.always),
                    .camera_cam => cam_layout.source(.webcam),
                    .camera_grd => cam_layout.source(.gradient),
                    else => unreachable,
                };
                return centerOf(rect);
            }
            return null;
        },
        .board_sw1, .board_sw2 => {
            var solved = shell_frame.solve(layout, allocator, width, height) catch return null;
            defer solved.deinit(allocator);
            for (solved.panes.items) |placed| {
                const pane = layout.pane(placed.index) orelse continue;
                if (pane.kind != .board) continue;
                const body = shell_frame.bodyOf(placed.area);
                var parts = if (board) |b| b.parts else board_pane.Parts{};
                if (parts.switch_names.len == 0) parts.switch_names = &default_switches;
                const bp_layout = board_pane.Layout.of(body, parts);
                const index: usize = if (named == .board_sw1) 0 else 1;
                if (index < bp_layout.switch_count) {
                    return centerOf(bp_layout.switches[index]);
                }
            }
            return null;
        },
    }
}

fn resolveTouch(
    allocator: std.mem.Allocator,
    layout: *const pane_layout.Layout,
    width: i32,
    height: i32,
    board: ?*const shell_board.Board,
    touch_x: u16,
    touch_y: u16,
) ?Point {
    var solved = shell_frame.solve(layout, allocator, width, height) catch return null;
    defer solved.deinit(allocator);
    for (solved.panes.items) |placed| {
        const pane = layout.pane(placed.index) orelse continue;
        if (pane.kind != .board) continue;
        const body = shell_frame.bodyOf(placed.area);
        var parts = if (board) |b| b.parts else board_pane.Parts{};
        if (parts.switch_names.len == 0) parts.switch_names = &default_switches;
        const bp_layout = board_pane.Layout.of(body, parts);

        var p_w: u32 = if (board) |b| b.width else 0;
        var p_h: u32 = if (board) |b| b.height else 0;
        if (p_w == 0) p_w = parts.panel.width;
        if (p_h == 0) p_h = parts.panel.height;
        if (p_w == 0) p_w = 480;
        if (p_h == 0) p_h = 272;

        const shown = board_touch.shownIn(bp_layout, p_w, p_h);
        if (shown.w <= 1 or shown.h <= 1 or p_w <= 1 or p_h <= 1) return centerOf(shown);

        const clamped_x: i64 = @min(@as(i64, touch_x), @as(i64, p_w) - 1);
        const clamped_y: i64 = @min(@as(i64, touch_y), @as(i64, p_h) - 1);

        const sx = shown.x + @as(i32, @intCast(@divTrunc(clamped_x * (@as(i64, shown.w) - 1), @as(i64, p_w) - 1)));
        const sy = shown.y + @as(i32, @intCast(@divTrunc(clamped_y * (@as(i64, shown.h) - 1), @as(i64, p_h) - 1)));
        return .{ .x = sx, .y = sy };
    }
    return null;
}

fn centerOf(r: Rect) Point {
    return .{
        .x = r.x + @divTrunc(r.w, 2),
        .y = r.y + @divTrunc(r.h, 2),
    };
}
