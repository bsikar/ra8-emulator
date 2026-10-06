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
