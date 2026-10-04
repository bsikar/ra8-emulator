//! `zig build usbip-attach -- PORT` (RA8EMU-75 slice 5c): attach the device
//! `--usbip PORT` exports the way `usbip list` and `usbip attach` do, then
//! check it end to end. It reads the device descriptor over ep0 and loops
//! 64 bytes through usb_printer_vendor's vendor interface (bulk OUT 0x02,
//! bulk IN 0x81). Exits 1 on the first step that does not hold.
const std = @import("std");
const client = @import("usbip_client");
const attach = client.attach;

const vendor: u16 = 0x1209;
const product: u16 = 0x0001;
const loop_len = 64;

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    const text = args.next() orelse return fail("usage: usbip_attach PORT", .{});
    const port = std.fmt.parseInt(u16, text, 10) catch return fail("bad port {s}", .{text});
    const address = try std.net.Address.parseIp4("127.0.0.1", port);

    var record: [312]u8 = undefined;
    const listed = try list(address, &record);
    std.debug.print("usbip_attach: listed {s} {x:0>4}:{x:0>4}\n", .{ listed.busid, listed.vendor, listed.product });
    if (listed.vendor != vendor or listed.product != product) return fail("not the printer/vendor device", .{});

    var busid: [32]u8 = undefined;
    const name = busid[0..listed.busid.len];
    @memcpy(name, listed.busid);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();
    const reader = stream.reader();
    const writer = stream.writer();
    const imported = try attach.import(reader, writer, name, &record);
    std.debug.print("usbip_attach: imported {s}\n", .{name});
    try descriptor(reader, writer, imported.devid());
    try loopback(reader, writer, imported.devid());
    std.debug.print("usbip_attach: passed\n", .{});
}

fn list(address: std.net.Address, record: *[312]u8) !client.Listed {
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();
    return (try attach.first(stream.reader(), stream.writer(), record)) orelse fail("no exports", .{});
}

/// GET_DESCRIPTOR(device) on ep0: idVendor and idProduct must match the list.
fn descriptor(reader: anytype, writer: anytype, devid: u32) !void {
    var in: [18]u8 = undefined;
    const urb = client.Urb{ .seqnum = 1, .devid = devid, .direction = .in, .ep = 0, .length = 18, .setup = client.getDescriptor(1, 0, 18) };
    const back = try attach.transfer(reader, writer, urb, &.{}, &in);
    if (back.status != 0 or back.actual != 18) return fail("device descriptor: status {d}, {d} bytes", .{ back.status, back.actual });
    const id_vendor = std.mem.readInt(u16, in[8..10], .little);
    const id_product = std.mem.readInt(u16, in[10..12], .little);
    std.debug.print("usbip_attach: device descriptor {x:0>4}:{x:0>4}\n", .{ id_vendor, id_product });
    if (id_vendor != vendor or id_product != product) return fail("descriptor does not match the list", .{});
}

/// Bulk OUT on ep 2, then bulk IN on ep 1: the firmware echoes the packet.
fn loopback(reader: anytype, writer: anytype, devid: u32) !void {
    var out: [loop_len]u8 = undefined;
    for (&out, 0..) |*byte, i| byte.* = @truncate(i * 7 + 3);
    const sent = try attach.transfer(reader, writer, .{ .seqnum = 2, .devid = devid, .direction = .out, .ep = 2, .length = loop_len }, &out, &.{});
    if (sent.status != 0 or sent.actual != loop_len) return fail("bulk OUT: status {d}, {d} bytes", .{ sent.status, sent.actual });
    var in: [loop_len]u8 = undefined;
    const back = try attach.transfer(reader, writer, .{ .seqnum = 3, .devid = devid, .direction = .in, .ep = 1, .length = loop_len }, &.{}, &in);
    if (back.status != 0 or back.actual != loop_len) return fail("bulk IN: status {d}, {d} bytes", .{ back.status, back.actual });
    if (!std.mem.eql(u8, &out, &in)) return fail("bulk IN does not echo bulk OUT", .{});
    std.debug.print("usbip_attach: vendor loopback {d} bytes echoed\n", .{loop_len});
}

fn fail(comptime format: []const u8, values: anytype) error{Failed} {
    std.debug.print("usbip_attach: " ++ format ++ "\n", values);
    std.process.exit(1);
}
