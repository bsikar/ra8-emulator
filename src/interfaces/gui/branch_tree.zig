//! Branch tree visualization (Slice 23.5).
//! Displays the branch graph hierarchy with bifurcation points, fork lines,
//! active line highlighting, and switch-branch actions.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("ui/colors.zig").Theme;
const branch_list = @import("ui/branch_list.zig");

pub const Item = branch_list.Item;
pub const Color = draw_list.Color;
pub const Rect = draw_list.Rect;

pub const node_width: i32 = 130;
pub const node_height: i32 = 32;
pub const lane_width: i32 = 145;
pub const row_step: i32 = 44;
pub const pad: i32 = 8;

pub const Action = union(enum) {
    none,
    switch_branch: u32,
};

pub const NodeLayout = struct {
    item: Item,
    lane: i32,
    row: i32,
    rect: Rect,
    switch_rect: Rect,
    fork_point: struct { x: i32, y: i32 },
    is_active_path: bool,
};

pub const max_nodes: usize = 32;

/// Where the node at `row` sits in `area`: the root on lane 0, every other
/// branch one lane across per row, up to the fifth lane.
pub fn nodeRect(area: Rect, row: usize) Rect {
    const lane: i32 = if (row == 0) 0 else @intCast(@min(row, 4));
    return .{ .x = area.x + pad + lane * lane_width, .y = area.y + 28 + @as(i32, @intCast(row)) * row_step, .w = node_width, .h = node_height };
}

pub const TreeLayout = struct {
    nodes: [max_nodes]NodeLayout = undefined,
    count: usize = 0,

    pub fn compute(area: Rect, items: []const Item) TreeLayout {
        var layout: TreeLayout = .{};
        const n = @min(items.len, max_nodes);
        if (n == 0 or area.empty()) return layout;

        // Determine active branch and trace active path
        var active_id: ?u32 = null;
        for (items[0..n]) |it| {
            if (it.is_live) {
                active_id = it.id;
                break;
            }
        }

        var is_active: [max_nodes]bool = @splat(false);
        if (active_id) |curr| {
            var walk: u32 = curr;
            var safety: usize = 0;
            while (safety < n) : (safety += 1) {
                for (0..n) |i| {
                    if (items[i].id == walk) {
                        is_active[i] = true;
                        if (items[i].parent == walk) break;
                        walk = items[i].parent;
                        break;
                    }
                }
                if (walk == 0) {
                    for (0..n) |i| {
                        if (items[i].id == 0) is_active[i] = true;
                    }
                    break;
                }
            }
        }

        // Assign lanes: root at lane 0, children by index or offset
        const base_x = area.x + pad;
        const base_y = area.y + 28;

        for (0..n) |i| {
            const it = items[i];
            const lane: i32 = if (it.id == 0 or it.id == it.parent) 0 else @as(i32, @intCast(@min(i, 4)));
            const row: i32 = @intCast(i);
            const nx = base_x + lane * lane_width;
            const ny = base_y + row * row_step;

            const n_rect = Rect{ .x = nx, .y = ny, .w = node_width, .h = node_height };
            const sw_rect = Rect{ .x = nx + node_width - 48, .y = ny + 4, .w = 44, .h = node_height - 8 };

            layout.nodes[i] = .{
                .item = it,
                .lane = lane,
                .row = row,
                .rect = n_rect,
                .switch_rect = sw_rect,
                .fork_point = .{ .x = nx, .y = ny + @divTrunc(node_height, 2) },
                .is_active_path = is_active[i],
            };
        }
        layout.count = n;
        return layout;
    }
};

pub fn hit(area: Rect, items: []const Item, x: i32, y: i32) Action {
    if (area.empty() or !area.contains(x, y)) return .none;
    const tree = TreeLayout.compute(area, items);
    for (0..tree.count) |i| {
        const node = tree.nodes[i];
        if (node.item.is_live) continue;
        if (node.switch_rect.contains(x, y) or node.rect.contains(x, y)) {
            return .{ .switch_branch = node.item.id };
        }
    }
    return .none;
}

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, area: Rect, items: []const Item) void {
    if (area.empty()) return;
    fillArea(table, area, theme.surface);
    drawBorder(table, area, theme.border);

    // Title bar
    drawText(table, area.x + pad, area.y + 6, "Branch Tree", theme.ink, theme.surface);
    fillArea(table, .{ .x = area.x, .y = area.y + 24, .w = area.w, .h = 1 }, theme.border);

    const tree = TreeLayout.compute(area, items);
    drawLines(table, theme, &tree);
    drawNodes(table, theme, &tree);
}

fn drawLines(table: *const widget.types.Paint, theme: *const Theme, tree: *const TreeLayout) void {
    for (0..tree.count) |i| {
        const child = tree.nodes[i];
        if (child.item.id == 0 or child.item.id == child.item.parent) continue;

        // Find parent node
        var parent_node: ?NodeLayout = null;
        for (0..tree.count) |p| {
            if (tree.nodes[p].item.id == child.item.parent) {
                parent_node = tree.nodes[p];
                break;
            }
        }
        const p = parent_node orelse continue;
        const color = if (child.is_active_path and p.is_active_path) theme.pc_cyan else theme.muted;

        // Fork bifurcation line: horizontal elbow from parent center-x to child center-x
        const start_x = p.rect.x + 20;
        const start_y = p.rect.y + p.rect.h;
        const mid_y = child.fork_point.y;
        const end_x = child.fork_point.x;

        // Vertical leg down from parent
        fillArea(table, .{ .x = start_x, .y = start_y, .w = 2, .h = mid_y - start_y }, color);
        // Horizontal leg to child
        fillArea(table, .{ .x = start_x, .y = mid_y, .w = end_x - start_x, .h = 2 }, color);
    }
}

fn drawNodes(table: *const widget.types.Paint, theme: *const Theme, tree: *const TreeLayout) void {
    for (0..tree.count) |i| {
        const node = tree.nodes[i];
        const bg_color = if (node.item.is_live) theme.well else theme.face;
        const border_color = if (node.is_active_path) theme.pc_cyan else theme.border;

        fillArea(table, node.rect, bg_color);
        drawBorder(table, node.rect, border_color);

        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "B{d} (r:{d})", .{ node.item.id, node.item.fork_r }) catch "Branch";
        drawText(table, node.rect.x + 4, node.rect.y + 8, label, theme.ink, bg_color);

        if (node.item.is_live) {
            drawText(table, node.rect.x + node.rect.w - 38, node.rect.y + 8, "Live", theme.pc_cyan, bg_color);
        } else {
            fillArea(table, node.switch_rect, theme.button_face);
            drawBorder(table, node.switch_rect, theme.border);
            drawText(table, node.switch_rect.x + 4, node.switch_rect.y + 3, "Switch", theme.ink, theme.button_face);
        }
    }
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
