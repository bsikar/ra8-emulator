//! What `ctl` prints for each answer (RA8EMU-747): one JSON object per
//! line with --json, one plain line without. Errors under --json go to
//! stdout too, so an agent reads a single stream.
const std = @import("std");
const proto = @import("../rpc/session_rpc.zig");

pub const Reg = struct { register: proto.Register, value: u32 };

pub fn loaded(w: anytype, json: bool, path: []const u8, bytes: usize) !void {
    if (json) return w.print("{{\"loaded\":{},\"bytes\":{d}}}\n", .{ std.json.fmt(path, .{}), bytes });
    try w.print("loaded {s} ({d} bytes)\n", .{ path, bytes });
}

pub fn stopped(w: anytype, json: bool, stop: proto.Stopped) !void {
    const core = @tagName(stop.core);
    const reason = @tagName(stop.reason);
    if (json) return w.print(
        "{{\"stopped\":{{\"core\":\"{s}\",\"reason\":\"{s}\",\"pc\":{d},\"detail\":{d}}}}}\n",
        .{ core, reason, stop.address, stop.detail },
    );
    try w.print("{s} stopped: {s} at 0x{x:0>8}\n", .{ core, reason, stop.address });
}

pub fn paused(w: anytype, json: bool) !void {
    try w.writeAll(if (json) "{\"paused\":true}\n" else "paused\n");
}

pub fn registers(w: anytype, json: bool, regs: []const Reg) !void {
    if (json) try w.writeAll("{\"registers\":{");
    for (regs, 0..) |reg, index| {
        const name = @tagName(reg.register);
        if (json) {
            try w.print("{s}\"{s}\":{d}", .{ if (index == 0) "" else ",", name, reg.value });
        } else {
            try w.print("{s}{s}=0x{x:0>8}", .{ if (index == 0) "" else " ", name, reg.value });
        }
    }
    try w.writeAll(if (json) "}}\n" else "\n");
}

pub fn memory(w: anytype, json: bool, address: u32, bytes: []const u8) !void {
    const hex = std.fmt.fmtSliceHexLower(bytes);
    if (json) return w.print("{{\"address\":{d},\"length\":{d},\"hex\":\"{}\"}}\n", .{ address, bytes.len, hex });
    try w.print("0x{x:0>8}: {}\n", .{ address, hex });
}

/// `milli` is thousandths of the default rate; zero is `max`.
pub fn speed(w: anytype, json: bool, milli: u64) !void {
    if (milli == 0) return w.writeAll(if (json) "{\"speed\":\"max\"}\n" else "speed max\n");
    const factor = @as(f64, @floatFromInt(milli)) / 1000.0;
    if (json) return w.print("{{\"speed\":{d}}}\n", .{factor});
    try w.print("speed {d}x\n", .{factor});
}

/// A breakpoint or watchpoint the server accepted, with its id.
pub fn point(w: anytype, json: bool, kind: []const u8, id: u32, address: u32, access: ?proto.Access) !void {
    if (json) {
        try w.print("{{\"{s}\":{d},\"address\":{d}", .{ kind, id, address });
        if (access) |how| try w.print(",\"access\":\"{s}\"", .{@tagName(how)});
        return w.writeAll("}\n");
    }
    try w.print("{s} {d} at 0x{x:0>8}", .{ kind, id, address });
    if (access) |how| try w.print(" on {s}", .{@tagName(how)});
    try w.writeAll("\n");
}

pub fn cleared(w: anytype, json: bool, id: u32) !void {
    if (json) return w.print("{{\"cleared\":{d}}}\n", .{id});
    try w.print("cleared {d}\n", .{id});
}

/// Report `err` (with the server's refusal `code` when it refused) and
/// return ctl's failure exit code.
pub fn failed(json: bool, err: anyerror, code: u16) u8 {
    if (json) {
        std.io.getStdOut().writer().print("{{\"error\":\"{s}\",\"code\":{d}}}\n", .{ @errorName(err), code }) catch {};
    } else {
        std.debug.print("ctl: {s} (code {d})\n", .{ @errorName(err), code });
    }
    return 1;
}

pub fn uart(w: anytype, json: bool, sent: proto.Uart) !void {
    if (!json) return w.writeAll(sent.bytes);
    try w.print("{{\"uart\":{{\"core\":\"{s}\",\"channel\":{d},\"text\":{}}}}}\n", .{ @tagName(sent.core), sent.channel, std.json.fmt(sent.bytes, .{}) });
}

pub fn timeout(w: anytype, json: bool, until: []const u8) !void {
    if (json) return w.print("{{\"timeout\":{{\"until\":{}}}}}\n", .{std.json.fmt(until, .{})});
    try w.print("\ntimed out waiting for {s}\n", .{until});
}
