//! The memory map pane (RA8EMU-781): one vertical bar per linker region that
//! holds anything, low addresses at the top, with each section a block
//! scaled to its size and coloured by kind; what is left of the bar is
//! free. Hovering a block names it with its range and size, and for a
//! section stored apart from where it runs, draws a line to the other copy.
//! A click gives the address the memory pane should move to.

const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const Theme = @import("colors.zig").Theme;
const widget_paint = @import("ra8_render").widget_paint;
const widget = @import("ra8_widget");
const layout_mod = @import("../map_layout.zig");
const region_map = @import("ra8_session").region.map;
const boot_slots = @import("ra8_session").boot_slots;
const Layout = layout_mod.Layout;
const Block = layout_mod.Block;
const Rect = draw_list.Rect;

pub const pad: i32 = 4;
pub const gap: i32 = 6;
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
pub const max_bars = 16;
const min_bar_w: i32 = 8;
const min_bar_h: i32 = 16;

/// Bar `slot` of `count` across `area`, below the label row and above the
/// hover row.
pub fn barRect(area: Rect, slot: usize, count: usize) Rect {
    const n: i32 = @intCast(count);
    const width = @divTrunc(area.w - 2 * pad - (n - 1) * gap, n);
    const x = area.x + pad + @as(i32, @intCast(slot)) * (width + gap);
    return .{ .x = x, .y = area.y + pad + row_h, .w = width, .h = area.h - 2 * pad - 2 * row_h };
}

/// Where `block` sits inside its region's bar, at least one pixel tall.
pub fn blockRect(layout: *const Layout, bar: Rect, block: Block) Rect {
    const region = layout.map.regions[block.region];
    const height: u64 = @intCast(bar.h);
    const top = (@as(u64, block.start - region.base) * height) / region.size;
    const bottom = ((block.end() - region.base) * height) / region.size;
    const tall: i32 = @intCast(@max(1, bottom - top));
    return .{ .x = bar.x + 1, .y = bar.y + @as(i32, @intCast(top)), .w = bar.w - 2, .h = tall };
}

fn usable(area: Rect, count: usize) bool {
    if (count == 0) return false;
    const bar = barRect(area, 0, count);
    return bar.w >= min_bar_w and bar.h >= min_bar_h;
}

/// The block under (x, y), the last drawn first, or null.
pub fn hit(layout: *const Layout, area: Rect, x: i32, y: i32) ?usize {
    var slots: [max_bars]usize = undefined;
    const bars = layout.bars(&slots);
    if (!usable(area, bars.len)) return null;
    var index = layout.count;
    while (index > 0) {
        index -= 1;
        const block = layout.blocks[index];
        const slot = std.mem.indexOfScalar(usize, bars, block.region) orelse continue;
        if (blockRect(layout, barRect(area, slot, bars.len), block).contains(x, y)) return index;
    }
    return null;
}

/// The address a click at (x, y) moves the memory pane to: the start of the
/// block under it.
pub fn click(layout: *const Layout, area: Rect, x: i32, y: i32) ?u32 {
    const index = hit(layout, area, x, y) orelse return null;
    return layout.blocks[index].start;
}

pub fn color(theme: *const Theme, kind: layout_mod.Kind) draw_list.Color {
    return switch (kind) {
        .code => theme.accent,
        .read_only => theme.pc_cyan,
        .initialised => theme.good,
        .zero_fill => theme.band,
        .no_init => theme.muted,
        .stack => theme.selected_face,
    };
}

/// Draw the pane through the shared Paint table (RA8EMU-1159): the fills,
/// outlines and lines dispatch through the table and the text is the
/// firmware's label widget, so no pane code emits raw glyph commands.
pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, layout: *const Layout, hover: ?usize) !void {
    var slots: [max_bars]usize = undefined;
    const bars = layout.bars(&slots);
    if (!usable(area, bars.len)) return;
    try list.pushClip(area);
    defer list.popClip();
    var target = widget_paint.Target{ .list = list };
    const paint = target.paint();
    fillArea(&paint, area, word(theme.background));
    for (bars, 0..) |region, slot| drawBar(&paint, theme, layout, barRect(area, slot, bars.len), region, hover);
    drawSlots(&paint, theme, layout, area, bars);
    if (hover) |index| drawHover(&paint, theme, area, layout, bars, index);
}

fn drawBar(table: *const widget.types.Paint, theme: *const Theme, layout: *const Layout, bar: Rect, region: usize, hover: ?usize) void {
    const name = font.fit(layout.map.regions[region].name, @intCast(bar.w));
    drawText(table, bar.x, bar.y - row_h + 2, name, word(theme.ink), word(theme.background));
    fillArea(table, bar, word(theme.border));
    fillArea(table, .{ .x = bar.x + 1, .y = bar.y + 1, .w = bar.w - 2, .h = bar.h - 2 }, word(theme.well));
    for (layout.items()) |block| {
        if (block.region != region) continue;
        fillArea(table, blockRect(layout, bar, block), word(color(theme, block.kind)));
    }
    drawMarks(table, theme, layout, bar, region);
    if (hover) |index| {
        const block = layout.blocks[index];
        if (block.region == region) fillArea(table, blockRect(layout, bar, block), word(theme.highlight));
    }
}

/// The screen y of an address in a region's bar, the same scaling the
/// blocks use, so a band drawn from it lines up with the stack block.
fn addressY(bar: Rect, region: region_map.Region, address: u64) i32 {
    const height: u64 = @intCast(bar.h);
    const offset = address -| region.base;
    return bar.y + @as(i32, @intCast(offset * height / region.size));
}

/// The live stack marks (RA8EMU-815): a band from the current SP down to
/// the lowest SP seen inside the stack block, the block red when the stack
/// overflowed, the band running on into whatever the linker placed under
/// it, and one ink line at the current SP.
fn drawMarks(table: *const widget.types.Paint, theme: *const Theme, layout: *const Layout, bar: Rect, region: usize) void {
    const marks = layout.marks orelse return;
    if (!marks.touched) return;
    const stack = layout.map.stack orelse return;
    const where = region_map.regionAt(layout.map.regions, stack.base, stack.size) orelse return;
    if (where != region) return;
    const reg = layout.map.regions[region];
    if (marks.overflowed()) {
        for (layout.items()) |block| {
            if (block.region == region and block.kind == .stack) fillArea(table, blockRect(layout, bar, block), word(theme.bad));
        }
    }
    const top = addressY(bar, reg, marks.low);
    const bottom = addressY(bar, reg, marks.current);
    fillArea(table, .{ .x = bar.x + 1, .y = top, .w = bar.w - 2, .h = @max(1, bottom - top) }, word(if (marks.overflowed()) theme.bad else theme.highlight));
    fillArea(table, .{ .x = bar.x + 1, .y = bottom, .w = bar.w - 2, .h = 1 }, word(theme.ink));
}

fn drawHover(table: *const widget.types.Paint, theme: *const Theme, area: Rect, layout: *const Layout, bars: []const usize, index: usize) void {
    const block = layout.blocks[index];
    var buffer: [128]u8 = undefined;
    const text = describe(&buffer, layout, block) catch return;
    const y = area.y + area.h - pad - row_h + 2;
    drawText(table, area.x + pad, y, font.fit(text, @intCast(area.w - 2 * pad)), word(theme.ink), word(theme.background));
    const other = block.pair orelse return;
    const from = centre(layout, area, bars, block) orelse return;
    const to = centre(layout, area, bars, layout.blocks[other]) orelse return;
    table.draw_line.?(table.user, from.x, from.y, to.x, to.y, word(theme.ink));
}

/// "name 0xSTART-0xEND N B", with where the other copy of a stored section is.
pub fn describe(buffer: []u8, layout: *const Layout, block: Block) ![]const u8 {
    const last: u32 = @intCast(block.end() - 1);
    const head = try std.fmt.bufPrint(buffer, "{s} {X:0>8}-{X:0>8} {d} B", .{ block.name, block.start, last, block.size });
    const other = block.pair orelse return head;
    const preposition = if (block.load) "runs at" else "loaded from";
    const tail = try std.fmt.bufPrint(buffer[head.len..], ", {s} {X:0>8}", .{ preposition, layout.blocks[other].start });
    return buffer[0 .. head.len + tail.len];
}

fn centre(layout: *const Layout, area: Rect, bars: []const usize, block: Block) ?struct { x: i32, y: i32 } {
    const slot = std.mem.indexOfScalar(usize, bars, block.region) orelse return null;
    const box = blockRect(layout, barRect(area, slot, bars.len), block);
    return .{ .x = box.x + @divTrunc(box.w, 2), .y = box.y + @divTrunc(box.h, 2) };
}

/// The dfu A/B boot-slot overlay (RA8EMU-778): an outline around the
/// bootloader and each slot on the MRAM bar, in the slot state's colour and
/// labelled, and an arrow from the slot the bootloader picks down to its
/// copy-to-run base on the SRAM bar.
fn drawSlots(table: *const widget.types.Paint, theme: *const Theme, layout: *const Layout, area: Rect, bars: []const usize) void {
    const dfu = layout.slots orelse return;
    const mram = regionOf(layout, boot_slots.layout.mram_base) orelse return;
    const slot = std.mem.indexOfScalar(usize, bars, mram) orelse return;
    const bar = barRect(area, slot, bars.len);
    const reg = layout.map.regions[mram];
    const boot = layout_mod.Slots.bootloader();
    const box = slotRect(bar, reg, boot);
    edges(table, box, word(theme.pc_cyan));
    drawText(table, box.x + 2, box.y + 2, font.fit("bootloader", @intCast(bar.w - 4)), word(theme.ink), word(theme.well));
    const box_a = drawSlot(table, theme, bar, reg, .a, dfu.a);
    const box_b = drawSlot(table, theme, bar, reg, .b, dfu.b);
    if (dfu.booted) |which| {
        drawRun(table, theme, layout, area, bars, dfu.run_base, if (which == .a) box_a else box_b);
    }
}

/// Outlines one slot on the bar and labels it; returns the outline box.
fn drawSlot(table: *const widget.types.Paint, theme: *const Theme, bar: Rect, reg: region_map.Region, which: boot_slots.Which, state: layout_mod.SlotState) Rect {
    const range = [2]u32{ boot_slots.baseOf(which), boot_slots.layout.slot_size };
    const box = slotRect(bar, reg, range);
    const border = switch (state.state) {
        .empty => theme.muted,
        .valid => theme.good,
        .bad_crc => theme.bad,
    };
    edges(table, box, word(border));
    var buffer: [32]u8 = undefined;
    const text = switch (state.state) {
        .valid => std.fmt.bufPrint(&buffer, "{s}{d}", .{ state.label(which), state.seq }) catch state.label(which),
        else => state.label(which),
    };
    drawText(table, box.x + 2, box.y + 2, font.fit(text, @intCast(bar.w - 4)), word(theme.ink), word(theme.well));
    return box;
}

/// A tick at the copy-to-run base on its bar and the arrow to it.
fn drawRun(table: *const widget.types.Paint, theme: *const Theme, layout: *const Layout, area: Rect, bars: []const usize, run_base: u32, from: Rect) void {
    const sram = regionOf(layout, run_base) orelse return;
    const slot = std.mem.indexOfScalar(usize, bars, sram) orelse return;
    const bar = barRect(area, slot, bars.len);
    const reg = layout.map.regions[sram];
    const y = addressY(bar, reg, run_base);
    fillArea(table, .{ .x = bar.x + 1, .y = y - 1, .w = bar.w - 2, .h = 3 }, word(theme.good));
    const x = from.x + @divTrunc(from.w, 2);
    table.draw_line.?(table.user, x, from.y + from.h, x, y, word(theme.ink));
}

/// A 1px outline around `box`.
fn edges(table: *const widget.types.Paint, box: Rect, border: u32) void {
    fillArea(table, .{ .x = box.x, .y = box.y, .w = box.w, .h = 1 }, border);
    fillArea(table, .{ .x = box.x, .y = box.y + box.h - 1, .w = box.w, .h = 1 }, border);
    fillArea(table, .{ .x = box.x, .y = box.y, .w = 1, .h = box.h }, border);
    fillArea(table, .{ .x = box.x + box.w - 1, .y = box.y, .w = 1, .h = box.h }, border);
}

/// The screen rect of an address range in its region's bar, at least one
/// pixel tall, the same scaling the blocks use.
fn slotRect(bar: Rect, reg: region_map.Region, range: [2]u32) Rect {
    const top = addressY(bar, reg, range[0]);
    const bottom = addressY(bar, reg, @as(u64, range[0]) + range[1]);
    return .{ .x = bar.x + 1, .y = top, .w = bar.w - 2, .h = @max(1, bottom - top) };
}

/// The region index holding `address`, or null.
fn regionOf(layout: *const Layout, address: u32) ?usize {
    return region_map.regionAt(layout.map.regions, address, 1);
}

/// One line of text as the firmware's label widget (RA8EMU-1159): the label
/// owns the face and the aligned rendering; the rect is this line's cell.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
    var buffer: [192]u8 = undefined;
    const n = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
    var descriptor = widget.label.Label{
        .paint = table,
        .text = buffer[0..n :0].ptr,
        .fg = fg,
        .bg = bg,
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

/// `area` filled with `shade` through the shared Paint table.
fn fillArea(table: *const widget.types.Paint, area: Rect, shade: u32) void {
    table.fill_rect.?(table.user, area.x, area.y, area.w, area.h, shade);
}

/// `shade` as the widget's 0x00RRGGBB colour word.
fn word(shade: draw_list.Color) u32 {
    return @as(u32, shade.r) << 16 | @as(u32, shade.g) << 8 | shade.b;
}
