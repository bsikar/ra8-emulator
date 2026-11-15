//! Inventory and reservations share one host registry across connections.
const std = @import("std");

const Ack = @import("session/rpc.zig").Ack;
const Context = @import("session/handlers.zig").Context;
const model = @import("ra8_host").targets;
const rpc = @import("ra8_rpc_wire");
const wire = @import("targets_wire.zig");

pub const routes = .{
    .{ @backingInt(wire.Method.list), list },
    .{ @backingInt(wire.Method.reserve), reserve },
    .{ @backingInt(wire.Method.release), release },
    .{ @backingInt(wire.Method.perform), perform },
};

pub fn list(context: *Context, _: struct {}) rpc.Outcome(wire.Text) {
    const registry = context.targets orelse return refuse(wire.Text, error.Unavailable);
    var out: std.Io.Writer = .fixed(context.scratch[0..@min(context.scratch.len, wire.max_json)]);
    out.writeByte('[') catch |err| return refuse(wire.Text, err);
    var first = true;
    for (registry.entries) |slot| {
        const entry = slot orelse continue;
        if (!first) out.writeByte(',') catch |err| return refuse(wire.Text, err);
        first = false;
        std.json.Stringify.value(.{
            .target = entry.target,
            .generation = entry.generation,
            .reserved = entry.owner != null,
        }, .{}, &out) catch |err| return refuse(wire.Text, err);
    }
    out.writeByte(']') catch |err| return refuse(wire.Text, err);
    return .{ .ok = .{ .json = out.buffered() } };
}

pub fn reserve(context: *Context, args: wire.Selection) rpc.Outcome(Ack) {
    const registry = context.targets orelse return refuse(Ack, error.Unavailable);
    registry.reserve(context, selection(args)) catch |err| return refuse(Ack, err);
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn release(context: *Context, _: struct {}) rpc.Outcome(Ack) {
    forget(context);
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn perform(context: *Context, args: wire.Perform) rpc.Outcome(wire.Text) {
    const registry = context.targets orelse return refuse(wire.Text, error.Unavailable);
    const json = registry.perform(context, selection(args), args.action, context.scratch) catch |err|
        return refuse(wire.Text, err);
    if (json.len > wire.max_json) return refuse(wire.Text, error.TooLarge);
    return .{ .ok = .{ .json = json } };
}

pub fn forget(context: *Context) void {
    if (context.targets) |registry| registry.release(context);
}

fn selection(args: anytype) model.Selection {
    return .{
        .host_id = args.host_id,
        .probe_id = args.probe_id,
        .board_id = args.board_id,
        .generation = args.generation,
        .disambiguation = args.disambiguation,
    };
}

fn refuse(comptime T: type, err: anyerror) rpc.Outcome(T) {
    const code = switch (err) {
        error.Unavailable => wire.codes.unavailable,
        error.StaleSelection, error.Disconnected => wire.codes.stale,
        error.AmbiguousIdentity => wire.codes.ambiguous,
        error.TargetBusy, error.AlreadyReserved => wire.codes.busy,
        error.NotReserved => wire.codes.ownership,
        error.Unsupported => wire.codes.unsupported,
        error.CustodianUnavailable => wire.codes.custodian,
        else => wire.codes.failed,
    };
    return .{ .err = @fromBackingInt(code) };
}
