//! State diff CLI command (Slice 23.5).
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const diff_wire = proto.diff_wire;
const Client = @import("client.zig").Client;

pub fn perform(client: *Client, w: anytype, json: bool, a: []const u8, b: []const u8) !void {
    const res = try client.call(proto.DiffWire, proto.DiffArgs, .diff, .{ .a = a, .b = b });
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var decoded = try diff_wire.decode(gpa, res.bytes);
    defer decoded.deinit(gpa);

    if (json) {
        try w.print("{{\"diff\":{{\"a\":\"{s}\",\"b\":\"{s}\",\"registers\":[", .{ a, b });
        for (decoded.regs, 0..) |r, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"core\":{d},\"name\":\"{s}\",\"val_a\":{d},\"val_b\":{d}}}", .{
                r.core, r.name, r.val_a, r.val_b,
            });
        }
        try w.writeAll("],\"memory_pages\":[");
        for (decoded.pages, 0..) |p, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"space\":{d},\"page_index\":{d},\"address\":{d}}}", .{
                p.space, p.page_index, p.address,
            });
        }
        try w.writeAll("],\"peripherals\":[");
        for (decoded.periphs, 0..) |p, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"unit\":\"{s}\",\"offset\":{d},\"old_val\":{d},\"new_val\":{d},\"changed_bytes\":{d}}}", .{
                p.unit, p.offset, p.old_val, p.new_val, p.changed_bytes,
            });
        }
        try w.writeAll("]}}\n");
        return;
    }

    try w.print("diff {s} -> {s}:\n", .{ a, b });
    if (decoded.regs.len == 0 and decoded.pages.len == 0 and decoded.periphs.len == 0) {
        try w.writeAll("  no differences\n");
        return;
    }
    if (decoded.regs.len > 0) {
        try w.writeAll("Registers:\n");
        for (decoded.regs) |r| {
            try w.print("  [cpu{d}] {s}: 0x{x:0>8} -> 0x{x:0>8}\n", .{ r.core, r.name, r.val_a, r.val_b });
        }
    }
    if (decoded.pages.len > 0) {
        try w.writeAll("Memory Pages (4 KiB):\n");
        for (decoded.pages) |p| {
            try w.print("  space {d} page {d} at 0x{x:0>8}\n", .{ p.space, p.page_index, p.address });
        }
    }
    if (decoded.periphs.len > 0) {
        try w.writeAll("Peripherals:\n");
        for (decoded.periphs) |p| {
            try w.print("  {s} +0x{x:0>4}: 0x{x:0>8} -> 0x{x:0>8} ({d} bytes changed)\n", .{
                p.unit, p.offset, p.old_val, p.new_val, p.changed_bytes,
            });
        }
    }
}
