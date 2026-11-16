//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Builds one screen's widget tree. Every node is a ra8_widget leaf or a
//! ra8_widget panel; this file only owns the storage they point into and
//! the few lines it takes to fill each descriptor from slices. Sizing is
//! the panel's own stack model: a child is either `sized` to a fixed extent
//! along its parent's axis or left to `grow`.

const std = @import("std");
const rw = @import("ra8_widget");
const theme = @import("theme.zig");
const actions = @import("actions.zig");
const fields = @import("fields.zig");
const controls = @import("controls.zig");
const measure = @import("paint.zig").measure;

pub const Widget = rw.types.Widget;
pub const Rect = rw.types.Rect;
pub const Paint = rw.types.Paint;
pub const Axis = rw.panel.Axis;
pub const Error = error{ OutOfMemory, TooManyNames, TooManyBindings, BadWidget };

pub const limits = struct {
    pub const arena_bytes: usize = 160 * 1024;
    pub const names: usize = 64;
    pub const bindings: usize = 32;
    pub const parts: usize = 24;
    pub const clip_bytes: usize = 127;
};

/// A widget the debug channel should publish under a stable name.
pub const Name = struct {
    ctx: *anyopaque,
    name: [:0]const u8,
};

/// A widget whose own state the app reads back after a tap.
pub const Binding = struct {
    field: fields.Field,
    index: u8 = 0,
    source: union(enum) {
        toggle: *const rw.toggle.Toggle,
        choice: *const rw.segmented.Segmented,
        page: *const rw.pager.Pager,
    },
    /// What the widget held when it was last read.
    seen: u16 = 0,

    pub fn value(self: Binding) u16 {
        return switch (self.source) {
            .toggle => |t| @intFromBool(t.checked),
            .choice => |s| s.selected,
            .page => |p| p.page,
        };
    }

    /// The widget's value when a tap changed it since the last read.
    pub fn changed(self: *Binding) ?u16 {
        const now = self.value();
        if (now == self.seen) return null;
        self.seen = now;
        return now;
    }
};

/// A short list of sibling widgets being collected for one panel.
pub const Parts = struct {
    items: [limits.parts]Widget = undefined,
    len: usize = 0,

    pub fn add(self: *Parts, w: Widget) Error!void {
        if (self.len == limits.parts) return error.OutOfMemory;
        self.items[self.len] = w;
        self.len += 1;
    }

    pub fn slice(self: *const Parts) []const Widget {
        return self.items[0..self.len];
    }
};

pub const Row = controls.Row;

pub const ButtonStyle = struct {
    fg: u32 = theme.color.ink,
    face: u32 = theme.color.paper,
    border: u32 = theme.color.ink,
    border_w: i16 = 2,
    alignment: theme.Alignment = .center,
    pad: i16 = 0,
    index: u8 = 0,

    pub const solid: ButtonStyle = .{ .fg = theme.color.paper, .face = theme.color.ink };
    pub const plain: ButtonStyle = .{ .border_w = 0 };
    pub const cover: ButtonStyle = .{ .fg = theme.color.muted, .face = theme.color.cover, .border_w = 0 };
};

pub const Builder = struct {
    buffer: [limits.arena_bytes]u8 = undefined,
    arena: std.heap.FixedBufferAllocator = undefined,
    paint: *const Paint = undefined,
    names: [limits.names]Name = undefined,
    name_count: usize = 0,
    bindings: [limits.bindings]Binding = undefined,
    binding_count: usize = 0,

    /// Drop the previous screen's tree and start an empty one.
    pub fn reset(self: *Builder, paint: *const Paint) void {
        self.arena = std.heap.FixedBufferAllocator.init(&self.buffer);
        self.paint = paint;
        self.name_count = 0;
        self.binding_count = 0;
    }

    pub fn create(self: *Builder, comptime T: type, value: T) Error!*T {
        const slot = try self.arena.allocator().create(T);
        slot.* = value;
        return slot;
    }

    pub fn ready(w: *Widget) Widget {
        w.dirty = true;
        w.refresh = @backingInt(rw.types.Refresh.quality);
        return w.*;
    }

    pub fn blank() Widget {
        return .{ .vt = null, .ctx = null, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .fixed = 0, .flex = 0, .action_id = 0, .refresh = 0, .visible = false, .dirty = false };
    }

    /// A formatted, NUL-terminated string that lives as long as the tree.
    pub fn fmt(self: *Builder, comptime format: []const u8, args: anytype) Error![:0]const u8 {
        return std.fmt.allocPrintZ(self.arena.allocator(), format, args);
    }

    pub fn label(self: *Builder, text: ?[:0]const u8, style: theme.Text) Error!Widget {
        const desc = try self.create(rw.label.Label, .{
            .paint = self.paint,
            .text = if (text) |t| t.ptr else null,
            .fg = style.fg,
            .bg = style.bg,
            .pad = style.pad,
            .alignment = style.alignment,
            .face = style.face,
            .weight = style.weight,
            .size = style.size,
        });
        var w = blank();
        if (rw.label.ra8_widget_label_init(&w, desc) != rw.types.err.ok) return error.BadWidget;
        return ready(&w);
    }

    /// A solid band: rules, spacers and plain boxes.
    pub fn fill(self: *Builder, color: u32) Error!Widget {
        return self.label(null, .{ .bg = color });
    }

    /// White space `extent` pixels long on the parent's axis.
    pub fn space(self: *Builder, extent: i16) Error!Widget {
        return sized(try self.fill(theme.color.paper), extent);
    }

    pub fn button(self: *Builder, text: ?[:0]const u8, action: actions.Id, style: ButtonStyle) Error!Widget {
        const desc = try self.create(rw.button.Button, .{
            .paint = self.paint,
            .text = if (text) |t| t.ptr else null,
            .on_press = actions.onPress,
            .fg = style.fg,
            .face = style.face,
            .face_pressed = style.face,
            .border = style.border,
            .presses = 0,
            .pad = style.pad,
            .border_w = style.border_w,
            .alignment = style.alignment,
            .pressed = false,
            .reserved = 0,
        });
        var w = blank();
        if (rw.button.ra8_widget_button_init(&w, desc) != rw.types.err.ok) return error.BadWidget;
        w.action_id = actions.encode(action, style.index);
        return ready(&w);
    }

    pub fn bind(self: *Builder, binding: Binding) Error!void {
        if (self.binding_count == limits.bindings) return error.TooManyBindings;
        self.bindings[self.binding_count] = binding;
        self.bindings[self.binding_count].seen = binding.value();
        self.binding_count += 1;
    }

    pub const toggle = controls.toggle;
    pub const segmented = controls.segmented;
    pub const list = controls.list;
    pub const pager = controls.pager;
    pub const navBar = controls.navBar;
    pub const progress = controls.progress;
    pub const toolbar = controls.toolbar;

    fn panel(self: *Builder, axis: Axis, gap: i16, pad: i16, kids: []const Widget) Error!Widget {
        const allocator = self.arena.allocator();
        const copies = try allocator.dupe(Widget, kids);
        const boxes = try allocator.alloc(rw.core.Box, kids.len + 1);
        const desc = try self.create(rw.panel.Panel, .{
            .children = copies.ptr,
            .box_scratch = @ptrCast(boxes.ptr),
            .count = @intCast(kids.len),
            .box_cap = @intCast(boxes.len),
            .gap = gap,
            .pad = pad,
            .axis = axis,
            .reserved = 0,
            .paint = self.paint,
            .bg = theme.color.paper,
        });
        var w = blank();
        if (rw.panel.ra8_widget_panel_init(&w, desc) != rw.types.err.ok) return error.BadWidget;
        return ready(&w);
    }

    /// Children stacked top to bottom, `gap` pixels apart.
    pub fn col(self: *Builder, gap: i16, kids: []const Widget) Error!Widget {
        return self.panel(.col, gap, 0, kids);
    }

    /// Children laid left to right, `gap` pixels apart.
    pub fn row(self: *Builder, gap: i16, kids: []const Widget) Error!Widget {
        return self.panel(.row, gap, 0, kids);
    }

    /// Children stacked top to bottom inside `pad` pixels on every side.
    pub fn padded(self: *Builder, gap: i16, pad: i16, kids: []const Widget) Error!Widget {
        return self.panel(.col, gap, pad, kids);
    }

    /// `text`, or its longest prefix that fits `width` pixels in `style`
    /// with ".." after it. Labels do not clip, so a string that could
    /// overrun its box is cut here first.
    pub fn clip(self: *Builder, text: [:0]const u8, style: theme.Text, width: i32) Error![:0]const u8 {
        if (measure(text.ptr, style) <= width) return text;
        var scratch: [limits.clip_bytes + 3:0]u8 = undefined;
        var keep: usize = @min(text.len, limits.clip_bytes);
        while (keep > 0) : (keep -= 1) {
            const candidate = std.fmt.bufPrintZ(&scratch, "{s}..", .{text[0..keep]}) catch continue;
            if (measure(candidate.ptr, style) <= width) break;
        }
        return self.fmt("{s}..", .{text[0..keep]});
    }

    /// Publish `w` on the debug channel as `name`.
    pub fn named(self: *Builder, name: [:0]const u8, w: Widget) Error!Widget {
        if (self.name_count == limits.names) return error.TooManyNames;
        self.names[self.name_count] = .{ .ctx = w.ctx orelse return error.BadWidget, .name = name };
        self.name_count += 1;
        return w;
    }

    /// The root of the finished tree, at a stable address.
    pub fn finish(self: *Builder, root: Widget) Error!*Widget {
        return self.create(Widget, root);
    }
};

/// `w` at a fixed extent along its parent's axis.
pub fn sized(w: Widget, extent: i16) Widget {
    var copy = w;
    copy.fixed = extent;
    copy.flex = 0;
    return copy;
}

/// `w` taking a share of whatever its parent has left.
pub fn grow(w: Widget) Widget {
    var copy = w;
    copy.fixed = 0;
    copy.flex = 1;
    return copy;
}

/// The children of `w` when it is a panel.
pub fn children(w: *Widget) ?[]Widget {
    if (w.vt != rw.panel.ra8_widget_panel_vtable()) return null;
    return rw.panel.children(w);
}
