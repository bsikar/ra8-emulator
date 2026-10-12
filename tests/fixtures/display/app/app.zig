//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The running UI: it owns the screen stack, builds the screen on top,
//! feeds it touches and buttons, and reports what each one damaged.

const std = @import("std");
const tree = @import("tree.zig");
const paint = @import("paint.zig");
const compose = @import("compose.zig");
const names = @import("names.zig");
const actions = @import("actions.zig");
const fields = @import("fields.zig");
const screen = @import("screen.zig");
const diff = @import("diff.zig");
const route = @import("route.zig");
const state_mod = @import("state.zig");
const Services = @import("data/services.zig").Services;

pub const Damage = compose.Damage;
pub const Error = tree.Error || compose.Error;

/// The hardware keys the UI answers to.
pub const Key = enum { power };

pub const App = struct {
    svc: Services,
    state: state_mod.State = .{},
    builder: tree.Builder = .{},
    canvas: *paint.Canvas,
    /// The frame the panel shows now, for finding what a rebuild changed.
    shown: []u8,
    paint: paint.Paint,
    root: ?*tree.Widget = null,
    on_screen: ?screen.Id = null,

    /// Set up in place: the tree storage is too large to return by value.
    pub fn init(self: *App, canvas: *paint.Canvas, shown: []u8, svc: Services) void {
        self.* = .{ .svc = svc, .canvas = canvas, .shown = shown, .paint = undefined };
        self.paint = paint.bind(canvas);
    }

    fn ctx(self: *const App) screen.Ctx {
        return .{ .state = &self.state, .svc = self.svc };
    }

    /// Build the top screen from scratch and paint it.
    fn rebuild(self: *App) Error!Damage {
        const id = self.state.stack.top();
        self.builder.reset(&self.paint);
        const root = try self.builder.finish(try screen.build(id, &self.builder, self.ctx()));
        self.root = root;
        names.publish(&self.builder, root);
        _ = try compose.all(root);
        const whole = self.on_screen != id;
        self.on_screen = id;
        return self.settle(whole);
    }

    /// Compare the canvas with what the panel shows and remember the new
    /// frame. A new screen is a clean whole-panel refresh; a rebuilt one
    /// refreshes only the box that changed.
    fn settle(self: *App, whole: bool) Damage {
        const box = diff.bounds(self.shown, self.canvas.pixels, self.canvas.width);
        @memcpy(self.shown, self.canvas.pixels);
        if (whole) return .{ .rect = compose.frame, .quality = true };
        return .{ .rect = box orelse .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .quality = false };
    }

    /// Paint the current screen for the first time.
    pub fn draw(self: *App) Error!Damage {
        self.on_screen = null;
        return self.rebuild();
    }

    /// Store what the bound widgets changed. True when a rebuild is due.
    fn sync(self: *App) bool {
        var stale = false;
        for (self.builder.bindings[0..self.builder.binding_count]) |*binding| {
            const value = binding.changed() orelse continue;
            const change: fields.Change = .{ .field = binding.field, .index = binding.index, .value = value };
            if (!route.store(&self.state, self.svc, change)) continue;
            if (fields.rebuilds(change.field)) stale = true;
        }
        return stale;
    }

    /// Finish an input: rebuild when the screen is out of date, otherwise
    /// repaint just the widgets that changed themselves.
    fn finish(self: *App, stale: bool) Error!?Damage {
        if (stale or self.on_screen != self.state.stack.top()) return try self.rebuild();
        const root = self.root orelse return null;
        names.publish(&self.builder, root);
        const damage = try compose.changed(root) orelse return null;
        @memcpy(self.shown, self.canvas.pixels);
        return damage;
    }

    /// A touch at panel pixel (`x`, `y`). Null when nothing changed.
    pub fn tap(self: *App, x: i32, y: i32) Error!?Damage {
        if (route.zone(&self.state, self.svc, x)) return try self.rebuild();
        const root = self.root orelse return null;
        _ = compose.touch(root, x, y);
        var stale = self.sync();
        if (actions.take()) |event| {
            if (route.act(&self.state, self.svc, event)) stale = true;
        }
        return self.finish(stale);
    }

    /// A hardware key press.
    pub fn press(self: *App, key: Key) Error!?Damage {
        switch (key) {
            .power => route.power(&self.state, self.svc),
        }
        return self.finish(true);
    }
};
