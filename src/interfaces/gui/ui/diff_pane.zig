//! State diff viewer pane (Slice 23.5).
//! Displays structured differences between two history positions:
//! CPU0/CPU1 registers, modified memory pages, and peripheral register deltas.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("colors.zig").Theme;
const history_position = @import("ra8_session").history_position;

pub const Position = history_position.Position;
pub const Color = draw_list.Color;
pub const Rect = draw_list.Rect;

pub const max_regs: usize = 32;
pub const max_pages: usize = 64;
pub const max_periphs: usize = 32;
pub const row_h: i32 = 18;
pub const pad: i32 = 6;

pub const RegItem = struct {
    core: u8 = 0,
    name: [8]u8 = undefined,
    name_len: u8 = 0,
    old_val: u32 = 0,
    new_val: u32 = 0,

    pub fn nameSlice(self: *const RegItem) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const PageItem = struct {
    address: u32 = 0,
    bytes_changed: u16 = 0,
};

pub const PeriphItem = struct {
    block: [16]u8 = undefined,
    block_len: u8 = 0,
    register: [16]u8 = undefined,
    reg_len: u8 = 0,
    old_val: u32 = 0,
    new_val: u32 = 0,

    pub fn blockSlice(self: *const PeriphItem) []const u8 {
        return self.block[0..self.block_len];
    }

    pub fn regSlice(self: *const PeriphItem) []const u8 {
        return self.register[0..self.reg_len];
    }
};

pub const DiffView = struct {
    has_data: bool = false,
    pos_a: Position = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
    pos_b: Position = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
    regs: [max_regs]RegItem = undefined,
    regs_len: usize = 0,
    pages: [max_pages]PageItem = undefined,
    pages_len: usize = 0,
    periphs: [max_periphs]PeriphItem = undefined,
    periphs_len: usize = 0,
    scroll_offset: i32 = 0,
    /// A diff was asked and answered, so an empty one reads as no changes
    /// rather than as nothing selected.
    picked: bool = false,
    /// What the header names: the two sides compared.
    label: [64]u8 = undefined,
    label_len: u8 = 0,

    pub fn clear(self: *DiffView) void {
        self.has_data = false;
        self.regs_len = 0;
        self.pages_len = 0;
        self.periphs_len = 0;
        self.scroll_offset = 0;
        self.picked = false;
        self.label_len = 0;
    }

    pub fn setLabel(self: *DiffView, text: []const u8) void {
        const n = @min(text.len, self.label.len);
        @memcpy(self.label[0..n], text[0..n]);
        self.label_len = @intCast(n);
    }

    pub fn labelSlice(self: *const DiffView) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn addReg(self: *DiffView, core: u8, name: []const u8, old_val: u32, new_val: u32) bool {
        if (self.regs_len >= max_regs) return false;
        var it = RegItem{ .core = core, .old_val = old_val, .new_val = new_val };
        const n = @min(name.len, it.name.len);
        @memcpy(it.name[0..n], name[0..n]);
        it.name_len = @intCast(n);
        self.regs[self.regs_len] = it;
        self.regs_len += 1;
        self.has_data = true;
        return true;
    }

    pub fn addPage(self: *DiffView, address: u32, bytes_changed: u16) bool {
        if (self.pages_len >= max_pages) return false;
        self.pages[self.pages_len] = .{ .address = address, .bytes_changed = bytes_changed };
        self.pages_len += 1;
        self.has_data = true;
        return true;
    }

    pub fn addPeriph(self: *DiffView, block: []const u8, register: []const u8, old_val: u32, new_val: u32) bool {
        if (self.periphs_len >= max_periphs) return false;
        var it = PeriphItem{ .old_val = old_val, .new_val = new_val };
        const bn = @min(block.len, it.block.len);
        @memcpy(it.block[0..bn], block[0..bn]);
        it.block_len = @intCast(bn);
        const rn = @min(register.len, it.register.len);
        @memcpy(it.register[0..rn], register[0..rn]);
        it.reg_len = @intCast(rn);
        self.periphs[self.periphs_len] = it;
        self.periphs_len += 1;
        self.has_data = true;
        return true;
    }

    pub fn totalRows(self: *const DiffView) usize {
        var count: usize = 1; // Header
        if (self.regs_len > 0) count += 1 + self.regs_len;
        if (self.pages_len > 0) count += 1 + self.pages_len;
        if (self.periphs_len > 0) count += 1 + self.periphs_len;
        return count;
    }

    pub fn scroll(self: *DiffView, delta: i32, area: Rect) void {
        const rows: i32 = @intCast(self.totalRows());
        const total_height = rows * row_h;
        const max_scroll = @max(0, total_height - area.h);
        self.scroll_offset = @max(0, @min(max_scroll, self.scroll_offset + delta));
    }
};

/// The step buttons at the header row's right end: move the compared stop
/// one earlier or one later.
pub const btn_w: i32 = 22;

pub const Action = enum { none, earlier, later };

pub fn buttonEarlier(area: Rect) Rect {
    return .{ .x = area.x + area.w - pad - 2 * btn_w - 2, .y = area.y + 2, .w = btn_w, .h = row_h - 2 };
}

pub fn buttonLater(area: Rect) Rect {
    return .{ .x = area.x + area.w - pad - btn_w, .y = area.y + 2, .w = btn_w, .h = row_h - 2 };
}

/// The step button under a point, if any.
pub fn hit(area: Rect, x: i32, y: i32) Action {
    if (area.empty()) return .none;
    if (buttonEarlier(area).contains(x, y)) return .earlier;
    if (buttonLater(area).contains(x, y)) return .later;
    return .none;
}

fn drawButtons(table: *const widget.types.Paint, theme: *const Theme, area: Rect) void {
    for ([_]struct { r: Rect, text: []const u8 }{
        .{ .r = buttonEarlier(area), .text = "<" },
        .{ .r = buttonLater(area), .text = ">" },
    }) |b| {
        fillArea(table, b.r, theme.button_face);
        drawBorder(table, b.r, theme.border);
        drawText(table, b.r.x + 7, b.r.y + 2, b.text, theme.ink, theme.button_face);
    }
}

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, area: Rect, view: *const DiffView) void {
    if (area.empty()) return;
    table.push_clip.?(table.user, area.x, area.y, area.w, area.h);
    fillArea(table, area, theme.surface);
    drawBorder(table, area, theme.border);
    drawButtons(table, theme, area);

    if (!view.has_data and !view.picked) {
        drawText(table, area.x + pad, area.y + pad, "No diff selected", theme.muted, theme.surface);
        table.pop_clip.?(table.user);
        return;
    }

    var curr_y = area.y + pad - view.scroll_offset;

    // Header
    const total_changes = view.regs_len + view.pages_len + view.periphs_len;
    var hdr_buf: [96]u8 = undefined;
    const hdr = if (view.label_len > 0)
        std.fmt.bufPrint(&hdr_buf, "Diff: {s} ({d} changes)", .{ view.labelSlice(), total_changes }) catch "Diff"
    else
        std.fmt.bufPrint(&hdr_buf, "Diff: b{d} r{d} -> b{d} r{d} ({d} changes)", .{
            view.pos_a.branch, view.pos_a.r, view.pos_b.branch, view.pos_b.r, total_changes,
        }) catch "Diff";
    drawRow(table, area, curr_y, hdr, theme.ink, theme.surface);
    curr_y += row_h;

    curr_y = drawRegs(table, theme, area, view, curr_y);
    curr_y = drawPages(table, theme, area, view, curr_y);
    _ = drawPeriphs(table, theme, area, view, curr_y);

    table.pop_clip.?(table.user);
}

fn drawRegs(table: *const widget.types.Paint, theme: *const Theme, area: Rect, view: *const DiffView, start_y: i32) i32 {
    if (view.regs_len == 0) return start_y;
    var y = start_y;
    var sec_buf: [40]u8 = undefined;
    const sec = std.fmt.bufPrint(&sec_buf, "[Registers ({d})]", .{view.regs_len}) catch "Regs";
    drawRow(table, area, y, sec, theme.pc_cyan, theme.surface);
    y += row_h;

    for (0..view.regs_len) |idx| {
        const it = view.regs[idx];
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  CPU{d} {s}: 0x{x:0>8} -> 0x{x:0>8}", .{
            it.core, it.nameSlice(), it.old_val, it.new_val,
        }) catch "reg";
        drawRow(table, area, y, line, theme.ink, theme.surface);
        y += row_h;
    }
    return y;
}

fn drawPages(table: *const widget.types.Paint, theme: *const Theme, area: Rect, view: *const DiffView, start_y: i32) i32 {
    if (view.pages_len == 0) return start_y;
    var y = start_y;
    var sec_buf: [40]u8 = undefined;
    const sec = std.fmt.bufPrint(&sec_buf, "[Memory Pages ({d})]", .{view.pages_len}) catch "Pages";
    drawRow(table, area, y, sec, theme.accent, theme.surface);
    y += row_h;

    for (0..view.pages_len) |idx| {
        const it = view.pages[idx];
        var buf: [64]u8 = undefined;
        const line = if (it.bytes_changed == 0)
            std.fmt.bufPrint(&buf, "  0x{x:0>8}: page differs", .{it.address}) catch "page"
        else
            std.fmt.bufPrint(&buf, "  0x{x:0>8}: {d} bytes modified", .{ it.address, it.bytes_changed }) catch "page";
        drawRow(table, area, y, line, theme.ink, theme.surface);
        y += row_h;
    }
    return y;
}

fn drawPeriphs(table: *const widget.types.Paint, theme: *const Theme, area: Rect, view: *const DiffView, start_y: i32) i32 {
    if (view.periphs_len == 0) return start_y;
    var y = start_y;
    var sec_buf: [40]u8 = undefined;
    const sec = std.fmt.bufPrint(&sec_buf, "[Peripherals ({d})]", .{view.periphs_len}) catch "Periphs";
    drawRow(table, area, y, sec, theme.pc_cyan, theme.surface);
    y += row_h;

    for (0..view.periphs_len) |idx| {
        const it = view.periphs[idx];
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  {s}.{s}: 0x{x:0>8} -> 0x{x:0>8}", .{
            it.blockSlice(), it.regSlice(), it.old_val, it.new_val,
        }) catch "periph";
        drawRow(table, area, y, line, theme.ink, theme.surface);
        y += row_h;
    }
    return y;
}

fn drawRow(table: *const widget.types.Paint, area: Rect, y: i32, text: []const u8, fg: Color, bg: Color) void {
    if (y + row_h < area.y or y > area.y + area.h) return;
    drawText(table, area.x + pad, y + 2, text, fg, bg);
}

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
