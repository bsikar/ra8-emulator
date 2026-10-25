//! Scripted input and widget tree inspection for Session (RA8EMU-810, RA8EMU-811).
const std = @import("std");
const api = @import("api.zig");
const widget_tree = @import("widget_tree.zig");
const tap_part = @import("tap_part.zig");
const input_script = @import("ra8_components").input_script;
const gt911 = @import("ra8_components").gt911;

const session_fork = @import("fork.zig");

const Session = api.Session;
const Core = api.Core;
const Widget = api.Widget;
const TapPart = api.TapPart;
const Button = api.Button;

pub fn widgets(self: *Session, allocator: std.mem.Allocator, core: Core) anyerror![]Widget {
    const address = self.widget_tree_addresses[@backingInt(core)] orelse return error.NoWidgetTree;
    return widget_tree.read(try self.view(core), address, allocator);
}

pub fn tapWidget(self: *Session, allocator: std.mem.Allocator, core: Core, at_ns: u64, name: []const u8) anyerror!void {
    try tapWidgetPart(self, allocator, core, at_ns, name, .centre);
}

pub fn tapWidgetPart(self: *Session, allocator: std.mem.Allocator, core: Core, at_ns: u64, name: []const u8, part: TapPart) anyerror!void {
    const tree = try widgets(self, allocator, core);
    defer allocator.free(tree);
    const point = try tap_part.aim(try tap_part.find(tree, name), part);
    try tap(self, core, at_ns, point.x, point.y);
}

pub fn tap(self: *Session, core: Core, at_ns: u64, x: u16, y: u16) anyerror!void {
    try scheduleInput(self, core, at_ns, .{ .tap = .{ .x = x, .y = y } });
}

pub fn swipe(self: *Session, core: Core, at_ns: u64, from: gt911.Contact, to: gt911.Contact, duration_ns: u64) anyerror!void {
    try scheduleInput(self, core, at_ns, .{ .swipe = .{ .from = from, .to = to, .duration_ns = duration_ns } });
}

pub fn longpress(self: *Session, core: Core, at_ns: u64, point: gt911.Contact, duration_ns: u64) anyerror!void {
    try scheduleInput(self, core, at_ns, .{ .longpress = .{ .point = point, .duration_ns = duration_ns } });
}

pub fn button(self: *Session, core: Core, at_ns: u64, which: Button) anyerror!void {
    try scheduleInput(self, core, at_ns, .{ .button = .{ .down = true, .button_id = which } });
}

pub fn scheduleInput(self: *Session, core: Core, at_ns: u64, event: input_script.Event) anyerror!void {
    return session_fork.scheduleInput(self, core, at_ns, event);
}
