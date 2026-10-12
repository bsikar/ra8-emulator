//! The timeline pane's paint (RA8EMU-836, piece 3 of 5 under RA8EMU-215):
//! Ozone-style, each core a header band, then one row per lane with its
//! name and load percent in a left column, slices as filled rects on
//! virtual time, ISR rows above thread rows, idle muted, and a time ruler
//! whose ticks adapt to the zoom. Paint only: the model lives in
//! timeline_model.zig and the shell (201) calls draw directly, with zoom
//! and pan going through the model's View. Theme colors only, no new
//! palette. The caller sets the view's width_px to the rows width.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const Theme = @import("ui/colors.zig").Theme;
pub const timeline_model = @import("timeline_model.zig");

const Rect = draw_list.Rect;
const Model = timeline_model.Model;
const View = timeline_model.View;

pub const pad: i32 = 4;
pub const header_h: i32 = @as(i32, @intCast(font.cell_h)) + 6;
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
pub const ruler_h: i32 = @as(i32, @intCast(font.cell_h)) + 8;
pub const col_w: i32 = 108;

/// The rows area: right of the name column, above the ruler.
pub fn rowsRect(area: Rect) Rect {
    return .{ .x = area.x + col_w, .y = area.y, .w = area.w - col_w, .h = area.h - ruler_h };
}

/// Lanes in draw order for one core: ISR rows above thread rows, idle
/// last, each group ascending by id. Fills `buf`, capped at its length.
pub fn laneOrder(model: *const Model, core: u1, buf: *[64]usize) []usize {
    var n: usize = 0;
    for (0..model.laneCount()) |index| {
        if (model.laneAt(index).core == core and n < buf.len) {
            buf[n] = index;
            n += 1;
        }
    }
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and laneLess(model, buf[j], buf[j - 1])) : (j -= 1) {
            const tmp = buf[j];
            buf[j] = buf[j - 1];
            buf[j - 1] = tmp;
        }
    }
    return buf[0..n];
}

fn laneLess(model: *const Model, a: usize, b: usize) bool {
    const la = model.laneAt(a);
    const lb = model.laneAt(b);
    const ka = kindOrder(la.kind);
    const kb = kindOrder(lb.kind);
    if (ka != kb) return ka < kb;
    return la.id < lb.id;
}

fn kindOrder(kind: timeline_model.rtos_load.Kind) u8 {
    return switch (kind) {
        .exception => 0,
        .thread => 1,
        .idle => 2,
        else => 3,
    };
}

fn sliceColor(theme: *const Theme, kind: timeline_model.rtos_load.Kind) @TypeOf(theme.muted) {
    return switch (kind) {
        .exception => theme.hue.purple,
        .thread => theme.hue.blue,
        else => theme.muted,
    };
}

fn laneName(lane: timeline_model.Lane, into: []u8) []const u8 {
    return switch (lane.kind) {
        .idle => "idle",
        .exception => std.fmt.bufPrint(into, "isr {d}", .{lane.id}) catch "isr",
        .thread => std.fmt.bufPrint(into, "thread 0x{x}", .{lane.id}) catch "thread",
        else => "",
    };
}

/// The pane's whole paint. A pane too small for the ruler, one core
/// header and one lane row draws nothing.
pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, model: *const Model, view: View) !void {
    if (area.w < col_w + 16 or area.h < ruler_h + header_h + row_h) return;
    try list.fill(area, theme.face);
    const rows = rowsRect(area);
    var y = area.y;
    for (0..timeline_model.limits.cores) |ci| {
        if (y >= area.y + rows.h) break;
        y = try drawCore(list, theme, area, model, view, @intCast(ci), y, area.y + rows.h);
    }
    try drawRuler(list, theme, area, view);
}

fn drawCore(list: *draw_list.DrawList, theme: *const Theme, area: Rect, model: *const Model, view: View, core: u1, y_top: i32, bottom: i32) !i32 {
    if (y_top + header_h > bottom) return bottom;
    try list.fill(.{ .x = area.x, .y = y_top, .w = area.w, .h = header_h }, theme.gutter);
    var cbuf: [16]u8 = undefined;
    const cname = std.fmt.bufPrint(&cbuf, "Core {d}", .{core}) catch "Core";
    try font.draw(list, area.x + pad, y_top + 3, cname, theme.ink);
    var order_buf: [64]usize = undefined;
    var y = y_top + header_h;
    for (laneOrder(model, core, &order_buf)) |index| {
        if (y + row_h > bottom) break;
        try drawLane(list, theme, area, model, view, index, y);
        y += row_h;
    }
    return y;
}

fn drawLane(list: *draw_list.DrawList, theme: *const Theme, area: Rect, model: *const Model, view: View, index: usize, y: i32) !void {
    const lane = model.laneAt(index);
    const rows = rowsRect(area);
    var nbuf: [40]u8 = undefined;
    const name = laneName(lane, &nbuf);
    var lbuf: [48]u8 = undefined;
    const label = if (model.lanePermille(index, view.start_ns, view.start_ns + view.span_ns)) |m|
        std.fmt.bufPrint(&lbuf, "{s} {d}%", .{ name, (m + 5) / 10 }) catch name
    else
        name;
    try font.draw(list, area.x + pad, y + 2, label, if (lane.kind == .idle) theme.muted else theme.ink);
    const color = sliceColor(theme, lane.kind);
    for (model.slicesOf(index)) |one| {
        const x0 = @max(view.nsToX(one.start_ns), 0);
        const x1 = @min(view.nsToX(one.end_ns), rows.w);
        if (x1 > x0) try list.fill(.{ .x = rows.x + x0, .y = y, .w = x1 - x0, .h = row_h - 2 }, color);
    }
}

fn drawRuler(list: *draw_list.DrawList, theme: *const Theme, area: Rect, view: View) !void {
    const rows = rowsRect(area);
    const line_y = area.y + rows.h + 4;
    try list.fill(.{ .x = area.x, .y = line_y, .w = area.w, .h = 1 }, theme.control_border);
    const step = rulerStep(view.span_ns);
    const end = view.start_ns + view.span_ns;
    var last_right: i32 = area.x + col_w - 40;
    var t = ((view.start_ns + step - 1) / step) * step;
    while (t < end) : (t += step) {
        const x = rows.x + view.nsToX(t);
        if (x > area.x + area.w) break;
        try list.fill(.{ .x = x, .y = line_y + 1, .w = 1, .h = 4 }, theme.control_border);
        var buf: [32]u8 = undefined;
        const label = stampLabel(t, &buf);
        const w: i32 = @intCast(font.textWidth(label.len));
        if (x + w <= area.x + area.w - pad and x - @divTrunc(w, 2) > last_right) {
            try font.draw(list, x - @divTrunc(w, 2), line_y + 7, label, theme.muted);
            last_right = x + @divTrunc(w, 2);
        }
    }
}

/// The widest 1-2-5 step holding at most 8 ticks across `span_ns`.
pub fn rulerStep(span_ns: u64) u64 {
    const mults = [_]u64{ 1, 2, 5 };
    var unit: u64 = 1;
    while (unit <= span_ns) {
        for (mults) |m| {
            const step = unit * m;
            if (span_ns / step <= 8) return step;
        }
        unit *= 10;
    }
    return unit;
}

fn stampLabel(ns: u64, into: []u8) []const u8 {
    const f: f64 = @floatFromInt(ns);
    if (ns >= 1_000_000_000) return std.fmt.bufPrint(into, "{d:.3}s", .{f / 1e9}) catch "";
    if (ns >= 1_000_000) return std.fmt.bufPrint(into, "{d:.3}ms", .{f / 1e6}) catch "";
    if (ns >= 1_000) return std.fmt.bufPrint(into, "{d:.3}us", .{f / 1e3}) catch "";
    return std.fmt.bufPrint(into, "{d}ns", .{ns}) catch "";
}
