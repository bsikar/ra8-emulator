//! Filmstrip thumbnails over recorded history (Slice 23.5).
//! Displays visual checkpoint thumbnails along the history strip track,
//! provides hover preview resolution with popover details, and click-to-seek.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("ui/colors.zig").Theme;
const history_position = @import("ra8_session").history_position;

pub const Position = history_position.Position;
pub const Color = draw_list.Color;
pub const Rect = draw_list.Rect;

pub const max_thumbnails: usize = 32;
pub const thumb_width: i32 = 16;
pub const thumb_height: i32 = 10;
pub const popover_width: i32 = 120;
pub const popover_height: i32 = 36;

pub const Thumbnail = struct {
    checkpoint_id: u32 = 0,
    position: Position = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
    virtual_ns: u64 = 0,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    has_frame: bool = false,
};

pub const PreviewBox = struct {
    rect: Rect,
    checkpoint_id: u32,
    virtual_ns: u64,
    position: Position,
};

pub const Filmstrip = struct {
    items_buf: [max_thumbnails]Thumbnail = undefined,
    items_len: usize = 0,
    hover_fraction: ?f64 = null,

    pub fn clear(self: *Filmstrip) void {
        self.items_len = 0;
        self.hover_fraction = null;
    }

    pub fn add(self: *Filmstrip, item: Thumbnail) bool {
        if (self.items_len >= max_thumbnails) return false;
        self.items_buf[self.items_len] = item;
        self.items_len += 1;
        return true;
    }

    pub fn items(self: *const Filmstrip) []const Thumbnail {
        return self.items_buf[0..self.items_len];
    }

    pub fn setHoverFraction(self: *Filmstrip, fraction: ?f64) void {
        self.hover_fraction = fraction;
    }

    pub fn updateLayout(self: *Filmstrip, strip: Rect, total_ns: u64) void {
        if (total_ns == 0 or strip.w <= 0) return;
        const body_w = @max(0, strip.w - 8);
        const body_x = strip.x + 4;
        const thumb_y = strip.y + @max(0, @divTrunc(strip.h - thumb_height, 2));

        for (0..self.items_len) |idx| {
            const it = &self.items_buf[idx];
            const frac = @as(f64, @floatFromInt(it.virtual_ns)) / @as(f64, @floatFromInt(total_ns));
            const clamped = @max(0.0, @min(1.0, frac));
            const center_x = body_x + @as(i32, @intFromFloat(@round(clamped * @as(f64, @floatFromInt(body_w)))));
            it.rect = .{
                .x = center_x - @divTrunc(thumb_width, 2),
                .y = thumb_y,
                .w = thumb_width,
                .h = thumb_height,
            };
        }
    }

    pub fn nearestIndex(self: *const Filmstrip, fraction: f64, total_ns: u64) ?usize {
        if (self.items_len == 0 or total_ns == 0) return null;
        const target_ns: u64 = @intFromFloat(@max(0.0, @min(1.0, fraction)) * @as(f64, @floatFromInt(total_ns)));
        var best_idx: usize = 0;
        var best_dist = if (self.items_buf[0].virtual_ns >= target_ns)
            self.items_buf[0].virtual_ns - target_ns
        else
            target_ns - self.items_buf[0].virtual_ns;

        for (1..self.items_len) |idx| {
            const ns = self.items_buf[idx].virtual_ns;
            const dist = if (ns >= target_ns) ns - target_ns else target_ns - ns;
            if (dist < best_dist) {
                best_dist = dist;
                best_idx = idx;
            }
        }
        return best_idx;
    }

    pub fn hoverPreview(self: *const Filmstrip, strip: Rect, total_ns: u64) ?PreviewBox {
        const frac = self.hover_fraction orelse return null;
        const idx = self.nearestIndex(frac, total_ns) orelse return null;
        const it = self.items_buf[idx];

        const body_w = @max(0, strip.w - 8);
        const center_x = strip.x + 4 + @as(i32, @intFromFloat(@round(frac * @as(f64, @floatFromInt(body_w)))));
        var box_x = center_x - @divTrunc(popover_width, 2);
        if (box_x < strip.x) box_x = strip.x;
        if (box_x + popover_width > strip.x + strip.w) box_x = strip.x + strip.w - popover_width;

        const box_y = strip.y - popover_height - 4;
        return PreviewBox{
            .rect = .{ .x = box_x, .y = box_y, .w = popover_width, .h = popover_height },
            .checkpoint_id = it.checkpoint_id,
            .virtual_ns = it.virtual_ns,
            .position = it.position,
        };
    }

    pub fn seekAt(self: *const Filmstrip, strip: Rect, x: i32, y: i32, total_ns: u64) ?u64 {
        _ = y;
        for (0..self.items_len) |idx| {
            const it = self.items_buf[idx];
            if (it.rect.contains(x, it.rect.y)) {
                return it.virtual_ns;
            }
        }
        if (strip.w <= 0 or total_ns == 0) return null;
        const body_x = strip.x + 4;
        const body_w = @max(1, strip.w - 8);
        if (x < body_x or x > body_x + body_w) return null;
        const frac = @as(f64, @floatFromInt(x - body_x)) / @as(f64, @floatFromInt(body_w));
        const idx = self.nearestIndex(frac, total_ns) orelse return null;
        return self.items_buf[idx].virtual_ns;
    }

    pub fn draw(self: *const Filmstrip, table: *const widget.types.Paint, theme: *const Theme, strip: Rect, total_ns: u64) void {
        for (0..self.items_len) |idx| {
            const it = self.items_buf[idx];
            if (it.rect.empty()) continue;
            fillArea(table, it.rect, theme.well);
            drawBorder(table, it.rect, theme.accent);
            if (it.has_frame) {
                const inner = Rect{
                    .x = it.rect.x + 2,
                    .y = it.rect.y + 2,
                    .w = @max(0, it.rect.w - 4),
                    .h = @max(0, it.rect.h - 4),
                };
                fillArea(table, inner, theme.pc_cyan);
            }
        }

        if (self.hoverPreview(strip, total_ns)) |prev| {
            fillArea(table, prev.rect, theme.surface);
            drawBorder(table, prev.rect, theme.pc_cyan);

            var line1_buf: [48]u8 = undefined;
            const line1 = std.fmt.bufPrint(&line1_buf, "CP #{d} ({d} us)", .{ prev.checkpoint_id, prev.virtual_ns / 1000 }) catch "CP";
            drawText(table, prev.rect.x + 4, prev.rect.y + 4, line1, theme.ink, theme.surface);

            var line2_buf: [48]u8 = undefined;
            const line2 = std.fmt.bufPrint(&line2_buf, "b:{d} r:{d} o:{d}", .{ prev.position.branch, prev.position.r, prev.position.o }) catch "pos";
            drawText(table, prev.rect.x + 4, prev.rect.y + 18, line2, theme.muted, theme.surface);
        }
    }
};

fn fillArea(table: *const widget.types.Paint, r: Rect, color: Color) void {
    if (r.empty()) return;
    table.fill_rect.?(table.user, r.x, r.y, r.w, r.h, word(color));
}

fn drawBorder(table: *const widget.types.Paint, r: Rect, color: Color) void {
    if (r.empty()) return;
    fillArea(table, .{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, color);
    fillArea(table, .{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, color);
    fillArea(table, .{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, color);
    fillArea(table, .{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, color);
}

fn word(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}

fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: Color, bg: Color) void {
    var buffer: [128]u8 = undefined;
    const n = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
    var descriptor = widget.label.Label{
        .paint = table,
        .text = buffer[0..n :0].ptr,
        .fg = word(fg),
        .bg = word(bg),
        .pad = 0,
        .alignment = .left,
        .face = .sans,
    };
    var w: widget.types.Widget = undefined;
    _ = widget.label.ra8_widget_label_init(&w, &descriptor);
    w.rect = .{
        .x = x,
        .y = y,
        .w = @intCast(font.textWidth(text.len)),
        .h = @intCast(font.cell_h),
    };
    w.vt.?.render.?(&w);
}
