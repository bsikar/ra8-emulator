//! `ctl ... cores` and `ctl ... step-back`: machine core discovery and
//! single-step rewind over session RPC.
const std = @import("std");

const Client = @import("client.zig").Client;
const out = @import("print.zig");
const proto = @import("ra8_rpc").session.rpc;

const wire = proto.cores_wire;

pub fn list(client: *Client, w: *std.Io.Writer, json: bool) !void {
    const reply = try client.call(proto.CoreList, struct {}, .list_cores, .{});
    return print(w, json, reply);
}

pub fn print(w: *std.Io.Writer, json: bool, reply: proto.CoreList) !void {
    const n = @min(@as(usize, reply.count), wire.count(reply.bytes));
    if (json) return writeJson(w, reply.machine, reply.bytes, n);
    for (0..n) |i| {
        const item = wire.get(reply.bytes, i);
        const state = if (item.attached != 0) "attached" else "unattached";
        try w.print(
            "{s} cpu{d}: {s} ({s}, cpuid=0x{x:0>8}, mve={})\n",
            .{ reply.machine, item.slot, item.nameSlice(), state, item.cpuid, item.flags & wire.flags.mve != 0 },
        );
    }
}

fn writeJson(w: *std.Io.Writer, machine: []const u8, bytes: []const u8, n: usize) !void {
    try w.print("{{\"machine\":{f},\"cores\":[", .{std.json.fmt(machine, .{})});
    for (0..n) |i| {
        if (i != 0) try w.writeByte(',');
        const item = wire.get(bytes, i);
        try w.print(
            "{{\"slot\":{d},\"attached\":{},\"name\":{f},\"cpuid\":{d}," ++
                "\"v8_1m\":{},\"mve\":{},\"lob\":{},\"security\":{},\"fpu\":\"{s}\",\"systicks\":{d}}}",
            .{
                item.slot,
                item.attached != 0,
                std.json.fmt(item.nameSlice(), .{}),
                item.cpuid,
                item.flags & wire.flags.v8_1m != 0,
                item.flags & wire.flags.mve != 0,
                item.flags & wire.flags.lob != 0,
                item.flags & wire.flags.security != 0,
                fpuName(item.fpu),
                item.systicks,
            },
        );
    }
    try w.writeAll("]}\n");
}

fn fpuName(code: u8) []const u8 {
    return switch (code) {
        0 => "none",
        1 => "single",
        2 => "double",
        else => "unknown",
    };
}

pub fn stepBack(client: *Client, w: *std.Io.Writer, json: bool) !void {
    _ = try client.call(proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });
    _ = try client.call(proto.Ack, proto.CoreOnly, .step_back, .{ .core = .cpu0 });
    try out.stopped(w, json, try client.stop());
}
