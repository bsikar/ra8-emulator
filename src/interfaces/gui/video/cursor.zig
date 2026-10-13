//! Visual cursor and click ripple overlay for GUI recordings (RA8EMU-1120).
const std = @import("std");
const raster = @import("ra8_render").raster;
const draw_list = @import("ra8_render").draw_list;
const runner_mod = @import("../script/runner.zig");

const Color = draw_list.Color;
const Framebuffer = raster.Framebuffer;
const Ripple = runner_mod.Ripple;

const cursor_w = 12;
const cursor_h = 18;

// 0 = none, 1 = black border, 2 = white fill
const cursor_bitmap: [cursor_h][cursor_w]u8 = .{
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 2, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 2, 2, 2, 2, 1, 0, 0, 0, 0, 0, 0 },
    .{ 1, 2, 2, 2, 2, 2, 1, 0, 0, 0, 0, 0 },
    .{ 1, 2, 2, 2, 2, 2, 2, 1, 0, 0, 0, 0 },
    .{ 1, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0, 0 },
    .{ 1, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
    .{ 1, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 0 },
    .{ 1, 2, 2, 1, 2, 2, 1, 0, 0, 0, 0, 0 },
    .{ 1, 2, 1, 0, 1, 2, 2, 1, 0, 0, 0, 0 },
    .{ 1, 1, 0, 0, 0, 1, 2, 2, 1, 0, 0, 0 },
    .{ 1, 0, 0, 0, 0, 1, 2, 2, 1, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 1, 2, 2, 1, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 1, 2, 2, 1, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0 },
};

pub fn draw(frame: *Framebuffer, cursor_x: i32, cursor_y: i32, ripples: []const Ripple, current_frame: u32) void {
    for (ripples) |r| {
        drawRipple(frame, r, current_frame);
    }
    drawPointer(frame, cursor_x, cursor_y);
}

fn drawPointer(frame: *Framebuffer, x: i32, y: i32) void {
    const border = Color{ .r = 0, .g = 0, .b = 0, .a = 230 };
    const fill = Color{ .r = 255, .g = 255, .b = 255, .a = 240 };

    for (0..cursor_h) |row| {
        const py = y + @as(i32, @intCast(row));
        if (py < 0 or py >= frame.height) continue;
        for (0..cursor_w) |col| {
            const px = x + @as(i32, @intCast(col));
            if (px < 0 or px >= frame.width) continue;
            const pixel_type = cursor_bitmap[row][col];
            if (pixel_type == 1) {
                frame.put(px, py, border);
            } else if (pixel_type == 2) {
                frame.put(px, py, fill);
            }
        }
    }
}

fn drawRipple(frame: *Framebuffer, r: Ripple, current_frame: u32) void {
    if (current_frame < r.frame or current_frame >= r.frame + r.duration) return;
    const elapsed = current_frame - r.frame;
    const progress = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(r.duration));
    const radius = 4.0 + 20.0 * progress;
    const alpha: u8 = @intFromFloat(190.0 * (1.0 - progress));
    if (alpha == 0) return;

    const ring_color = Color{ .r = 60, .g = 160, .b = 255, .a = alpha };
    const irad: i32 = @intFromFloat(radius);
    const r_sq_inner = @as(i32, @intFromFloat((radius - 1.5) * (radius - 1.5)));
    const r_sq_outer = @as(i32, @intFromFloat((radius + 1.5) * (radius + 1.5)));

    var dy: i32 = -irad - 2;
    while (dy <= irad + 2) : (dy += 1) {
        const py = r.y + dy;
        if (py < 0 or py >= frame.height) continue;
        const dy2 = dy * dy;
        var dx: i32 = -irad - 2;
        while (dx <= irad + 2) : (dx += 1) {
            const px = r.x + dx;
            if (px < 0 or px >= frame.width) continue;
            const dist_sq = dx * dx + dy2;
            if (dist_sq >= r_sq_inner and dist_sq <= r_sq_outer) {
                frame.put(px, py, ring_color);
            }
        }
    }
}
