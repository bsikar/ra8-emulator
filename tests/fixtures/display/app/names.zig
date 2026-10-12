//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Publishes the tree's named widgets on ra8_widget's debug channel, and
//! looks a published widget up again by name. The channel exists only in a
//! Debug build, so in any other mode both halves compile to nothing.

const std = @import("std");
const builtin = @import("builtin");
const rw = @import("ra8_widget");
const tree = @import("tree.zig");

pub const enabled = builtin.mode == .Debug;

const debug = if (enabled) @import("widget_debug") else struct {};

const Widget = tree.Widget;

/// One published widget, as a flow or a test reads it.
pub const Record = struct {
    name: []const u8,
    kind: []const u8,
    state: []const u8,
    rect: tree.Rect,
};

var registered: [tree.limits.names]*Widget = undefined;
var registered_count: usize = 0;

fn kindOf(w: *const Widget) [:0]const u8 {
    const vt = w.vt orelse return "none";
    if (vt == rw.button.ra8_widget_button_vtable()) return "button";
    if (vt == rw.list.ra8_widget_list_vtable()) return "list";
    if (vt == rw.nav_bar.ra8_widget_nav_bar_vtable()) return "nav_bar";
    if (vt == rw.pager.ra8_widget_pager_vtable()) return "pager";
    if (vt == rw.segmented.ra8_widget_segmented_vtable()) return "segmented";
    if (vt == rw.toggle.ra8_widget_toggle_vtable()) return "toggle";
    if (vt == rw.toolbar.ra8_widget_toolbar_vtable()) return "toolbar";
    if (vt == rw.panel.ra8_widget_panel_vtable()) return "panel";
    return "label";
}

/// The readable state a flow needs to aim inside a widget: how many cells
/// or rows it has, how tall a row is, and what is selected.
fn stateOf(w: *const Widget, buffer: *[24]u8) [:0]const u8 {
    const ctx = w.ctx orelse return "";
    const vt = w.vt.?;
    const out = if (vt == rw.list.ra8_widget_list_vtable()) blk: {
        const list: *const rw.list.List = @ptrCast(@alignCast(ctx));
        break :blk std.fmt.bufPrintZ(buffer, "n={d} h={d}", .{ list.count, list.row_height });
    } else if (vt == rw.nav_bar.ra8_widget_nav_bar_vtable()) blk: {
        const nav: *const rw.nav_bar.NavBar = @ptrCast(@alignCast(ctx));
        break :blk std.fmt.bufPrintZ(buffer, "n={d} sel={d}", .{ nav.count, nav.active });
    } else if (vt == rw.segmented.ra8_widget_segmented_vtable()) blk: {
        const control: *const rw.segmented.Segmented = @ptrCast(@alignCast(ctx));
        break :blk std.fmt.bufPrintZ(buffer, "n={d} sel={d}", .{ control.count, control.selected });
    } else if (vt == rw.pager.ra8_widget_pager_vtable()) blk: {
        const pager: *const rw.pager.Pager = @ptrCast(@alignCast(ctx));
        const pages = rw.pager.pageCount(pager.item_count, pager.page_capacity);
        break :blk std.fmt.bufPrintZ(buffer, "page={d} of={d}", .{ pager.page + 1, pages });
    } else if (vt == rw.toggle.ra8_widget_toggle_vtable()) blk: {
        const toggle: *const rw.toggle.Toggle = @ptrCast(@alignCast(ctx));
        break :blk std.fmt.bufPrintZ(buffer, "{s}", .{if (toggle.checked) "on" else "off"});
    } else return "";
    return out catch "";
}

fn forget() void {
    if (!enabled) return;
    for (registered[0..registered_count]) |w| _ = debug.ra8_widget_debug_unregister(@ptrCast(w));
    registered_count = 0;
}

fn register(b: *const tree.Builder, w: *Widget) void {
    for (b.names[0..b.name_count]) |entry| {
        if (entry.ctx != w.ctx) continue;
        var buffer: [24]u8 = undefined;
        const state = stateOf(w, &buffer);
        if (debug.ra8_widget_debug_register(@ptrCast(w), entry.name.ptr, kindOf(w).ptr, state.ptr) != debug.err.ok) return;
        registered[registered_count] = w;
        registered_count += 1;
        return;
    }
}

fn walk(b: *const tree.Builder, w: *Widget) void {
    register(b, w);
    const kids = tree.children(w) orelse return;
    for (kids) |*kid| walk(b, kid);
}

/// Register every named widget under `root` with its current state. Call
/// before a compose, which is what publishes the tree.
pub fn publish(b: *const tree.Builder, root: *Widget) void {
    if (!enabled) return;
    forget();
    walk(b, root);
}

fn text(bytes: []const u8) []const u8 {
    return std.mem.sliceTo(bytes, 0);
}

/// The published record called `name`, from the last compose.
pub fn find(name: []const u8) ?Record {
    if (!enabled) return null;
    const channel = &debug.ra8_widget_debug_tree;
    for (channel.records[0..channel.count]) |*record| {
        if (!std.mem.eql(u8, text(&record.name), name)) continue;
        return .{
            .name = text(&record.name),
            .kind = text(&record.kind),
            .state = text(&record.state),
            .rect = .{ .x = record.rect.x, .y = record.rect.y, .w = record.rect.w, .h = record.rect.h },
        };
    }
    return null;
}

/// True when the last published tree did not fit the channel.
pub fn truncated() bool {
    if (!enabled) return false;
    return debug.ra8_widget_debug_tree.truncated;
}

/// How many widgets the last compose published.
pub fn count() usize {
    if (!enabled) return 0;
    return debug.ra8_widget_debug_tree.count;
}
