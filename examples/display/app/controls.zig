//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The ra8_widget controls a screen is assembled from, beyond labels,
//! buttons and panels: toggle, segmented control, list, pager, nav bar,
//! progress bar and toolbar. Each fills one descriptor from slices and binds
//! it; the builder in tree.zig exposes them as its own methods.

const rw = @import("ra8_widget");
const tree = @import("tree.zig");
const theme = @import("theme.zig");
const actions = @import("actions.zig");
const fields = @import("fields.zig");

const Builder = tree.Builder;
const Widget = tree.Widget;
const Error = tree.Error;

pub const Row = struct {
    title: [:0]const u8,
    subtitle: ?[:0]const u8 = null,
    value: ?[:0]const u8 = null,
    chevron: bool = false,
};

pub fn toggle(self: *Builder, text: [:0]const u8, checked: bool, field: fields.Field, index: u8) Error!Widget {
    const desc = try self.create(rw.toggle.Toggle, .{
        .paint = self.paint,
        .label = text.ptr,
        .fg = theme.color.ink,
        .bg = theme.color.paper,
        .border = theme.color.ink,
        .mark = theme.color.ink,
        .box_size = theme.metric.toggle_box,
        .gap = 24,
        .checked = checked,
        .reserved = .{ 0, 0, 0 },
    });
    var w = Builder.blank();
    if (rw.toggle.ra8_widget_toggle_init(&w, desc) != rw.types.err.ok) return error.BadWidget;
    try self.bind(.{ .field = field, .index = index, .source = .{ .toggle = desc } });
    return Builder.ready(&w);
}

pub fn segmented(self: *Builder, labels: []const [:0]const u8, selected: u8, field: fields.Field) Error!Widget {
    const pointers = try self.arena.allocator().alloc([*:0]const u8, labels.len);
    for (labels, pointers) |text, *pointer| pointer.* = text.ptr;
    const desc = try self.create(rw.segmented.Segmented, .{
        .paint = self.paint,
        .labels = pointers.ptr,
        .fg = theme.color.ink,
        .selected_fg = theme.color.paper,
        .bg = theme.color.paper,
        .selected_bg = theme.color.ink,
        .border = theme.color.ink,
        .count = @intCast(labels.len),
        .selected = selected,
        .pad = 0,
    });
    var w = Builder.blank();
    if (rw.segmented.ra8_widget_segmented_init(&w, desc) != rw.types.err.ok) return error.BadWidget;
    try self.bind(.{ .field = field, .source = .{ .choice = desc } });
    return Builder.ready(&w);
}

/// Rows of one height. A tapped row posts `action` with `base` plus its
/// own position, so several lists on a screen can share one action.
pub fn list(self: *Builder, rows: []const Row, row_height: i16, action: actions.Id, base: u8) Error!Widget {
    const out = try self.arena.allocator().alloc(rw.list.Row, rows.len);
    for (rows, out) |spec, *slot| slot.* = .{
        .title = spec.title.ptr,
        .subtitle = if (spec.subtitle) |s| s.ptr else null,
        .trailing_text = if (spec.value) |v| v.ptr else null,
        .action_id = actions.encode(action, base),
        .trailing = if (spec.value != null) .value else if (spec.chevron) .chevron else .none,
    };
    const desc = try self.create(rw.list.List, .{
        .paint = self.paint,
        .rows = out.ptr,
        .count = @intCast(rows.len),
        .on_select = actions.onRow,
        .bg = theme.color.paper,
        .title_fg = theme.color.ink,
        .subtitle_fg = theme.color.ink,
        .trailing_fg = theme.color.ink,
        .divider = theme.color.ink,
        .row_height = row_height,
        .pad = theme.metric.text_pad,
        .selected = 0,
        .has_selection = false,
        .damage = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
    var w = Builder.blank();
    if (rw.list.ra8_widget_list_init(&w, desc) != rw.types.err.ok) return error.BadWidget;
    return tree.sized(Builder.ready(&w), @intCast(row_height * @as(i32, @intCast(rows.len))));
}

pub fn pager(self: *Builder, item_count: u16, capacity: u16, page: u16, field: fields.Field) Error!Widget {
    const desc = try self.create(rw.pager.Pager, .{
        .paint = self.paint,
        .item_count = item_count,
        .page_capacity = capacity,
        .page = page,
        .bg = theme.color.paper,
        .fg = theme.color.ink,
        .fg_disabled = theme.color.cover,
    });
    var w = Builder.blank();
    if (rw.pager.ra8_widget_pager_init(&w, desc) != rw.types.err.ok) return error.BadWidget;
    try self.bind(.{ .field = field, .source = .{ .page = desc } });
    return Builder.ready(&w);
}

pub fn navBar(self: *Builder, items: []const [:0]const u8, active: u16, action: actions.Id) Error!Widget {
    const pointers = try self.arena.allocator().alloc(?[*:0]const u8, items.len);
    for (items, pointers) |text, *pointer| pointer.* = text.ptr;
    const desc = try self.create(rw.nav_bar.NavBar, .{
        .paint = self.paint,
        .items = pointers.ptr,
        .on_select = actions.onCell,
        .bg = theme.color.paper,
        .fg_active = theme.color.ink,
        .fg_muted = theme.color.muted,
        .count = @intCast(items.len),
        .active = active,
        .selected = active,
    });
    var w = Builder.blank();
    if (rw.nav_bar.ra8_widget_nav_bar_init(&w, desc) != rw.types.err.ok) return error.BadWidget;
    w.action_id = actions.encode(action, 0);
    return Builder.ready(&w);
}

pub fn progress(self: *Builder, value: u16, total: u16) Error!Widget {
    const desc = try self.create(rw.progress_bar.ProgressBar, .{
        .paint = self.paint,
        .track = theme.color.cover,
        .fill = theme.color.ink,
        .value = value,
        .total = total,
    });
    var w = Builder.blank();
    if (rw.progress_bar.ra8_widget_progress_bar_init(&w, desc) != rw.types.err.ok) return error.BadWidget;
    return Builder.ready(&w);
}

pub fn toolbar(self: *Builder, hint: [:0]const u8, count: [:0]const u8) Error!Widget {
    const desc = try self.create(rw.toolbar.Toolbar, .{
        .paint = self.paint,
        .hint = hint.ptr,
        .count = count.ptr,
        .on_search = actions.onPress,
        .bg = theme.color.paper,
        .field = theme.color.paper,
        .border = theme.color.ink,
        .hint_fg = theme.color.ink,
        .count_fg = theme.color.ink,
        .searches = 0,
        .pad = 16,
        .border_w = 2,
        .count_w = 240,
    });
    var w = Builder.blank();
    if (rw.toolbar.ra8_widget_toolbar_init(&w, desc) != rw.types.err.ok) return error.BadWidget;
    w.action_id = actions.encode(.search_go, 0);
    return Builder.ready(&w);
}
