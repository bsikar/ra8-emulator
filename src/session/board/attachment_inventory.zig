//! Reflected classification of every owned catalog and wrapper field.
const std = @import("std");
const c = @import("ra8_components");
const fields = @import("ra8_board").snapshot.run.fields;
const Plugs = @import("plug.zig").Plugs;
const Faults = @import("faults/faults.zig").Faults;
const Asks = @import("ra8_board").plug.Asks;

pub fn complete() bool {
    return fields.complete(Plugs, .{ "instances", "instance_count", "instance_endpoints", "snapshot_owned", "snapshot_owned_count", "snapshot_endpoints", "fitted", "fitted_count", "panels" }, .{
        .{ .name = "board", .reason = "Stable target Board binding" },
        .{ .name = "arena", .reason = "Allocation wiring; every reachable pointed-to guest object is a typed node" },
    }) and fields.complete(Faults, .{ "wrapped", "spi_parts", "uart_parts" }, .{
        .{ .name = "board", .reason = "Stable target Board binding" },
        .{ .name = "arena", .reason = "Allocation wiring; wrappers are typed nodes" },
    }) and fields.complete(Asks, .{ "asked", "count", "attached_eink", "owned", "owned_count" }, .{
        .{ .name = "arena", .reason = "Target allocator; actual owned startup objects join typed graph and transfer to Plugs at commit" },
    }) and automatic(c.lsm6dso.Imu, .{}) and automatic(c.max17048.Gauge, .{}) and
        automatic(c.eink.Panel, .{ "planes", "refresh_hook", "refresh_log_hook", "event_hook" }) and
        automatic(@FieldType(c.eink.Panel, "planes"), .{ "allocator", "image", "glass" }) and
        automatic(c.modem_at.Modem, .{}) and automatic(c.esp_hosted.C6, .{ "pins", "wire" }) and
        automatic(@FieldType(c.esp_hosted.C6, "wire"), .{"bridge"}) and
        automatic(c.button.Button, .{"link"}) and automatic(c.led.Led, .{}) and
        automatic(c.fault.I2c, .{ "inner", "clock" }) and automatic(c.fault.lines.Spi, .{"inner"}) and
        automatic(c.fault.lines.Uart, .{ "inner", "reply" });
}

/// Unskipped fields are structurally encoded. Unknown pointers fail compilation.
/// The omitted paths below have typed guest payloads or explicit wiring reasons.
const Omitted = struct { name: []const u8, reason: []const u8 };

fn automatic(comptime T: type, comptime skip: anytype) bool {
    comptime var saved: []const []const u8 = &.{};
    comptime var omitted: []const Omitted = &.{};
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        comptime var found = false;
        inline for (skip) |one| if (comptime std.mem.eql(u8, one, name)) {
            found = true;
        };
        if (comptime found) {
            omitted = omitted ++ [_]Omitted{.{ .name = name, .reason = reason(name) }};
        } else saved = saved ++ .{name};
    }
    return fields.complete(T, saved, omitted);
}

fn reason(comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "planes") or std.mem.eql(u8, name, "image") or std.mem.eql(u8, name, "glass")) return "Pointed-to guest pixels saved in panel payload";
    if (std.mem.eql(u8, name, "inner")) return "Pointed-to guest device saved by node ID";
    if (std.mem.eql(u8, name, "link")) return "Button link presence/port/pin saved; pins rebind to stable target";
    if (std.mem.eql(u8, name, "wire")) return "Recursive guest link payload saved separately";
    if (std.mem.eql(u8, name, "reply")) return "Scratch UART fault return buffer overwritten before any read";
    if (std.mem.eql(u8, name, "bridge")) return "Host flows closed only at commit; target resolver/tape/net/worker ownership retained";
    return "Allocator, clock, host callback or stable target wiring, rebound at commit";
}
