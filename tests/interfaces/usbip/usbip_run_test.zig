//! Covers src/interfaces/usbip/usbip_run.zig: `--usbip` offers the FS device
//! after a run, and says so plainly when there is nothing to offer.
const std = @import("std");
const ra8 = @import("ra8");
const wire = ra8.core.cli.usbip_wire;
const exp = ra8.core.cli.usbip_export;

/// A CDC ACM device: class 0xEF/2/1 (IAD), VID 0x045B PID 0x5310, bcd 1.00.
const device = [_]u8{ 18, 1, 0x00, 0x02, 0xEF, 0x02, 0x01, 64, 0x5B, 0x04, 0x10, 0x53, 0x00, 0x01, 1, 2, 3, 1 };

/// Configuration 1: an IAD, a CDC communication interface with one
/// functional descriptor and an interrupt endpoint, a data interface with
/// two bulk endpoints, and an alternate setting that must not be listed.
const config = [_]u8{
    9,  2,  75,   0,    2,    1, 0,    0x80, 50,
    8,  11, 0,    2,    2,    2, 1,    0,    9,
    4,  0,  0,    1,    2,    2, 1,    0,    5,
    36, 0,  0x10, 0x01, 7,    5, 0x83, 3,    16,
    0,  16, 9,    4,    1,    0, 2,    0x0A, 0,
    0,  0,  7,    5,    0x81, 2, 0,    2,    0,
    7,  5,  0x01, 2,    0,    2, 0,    9,    4,
    1,  1,  0,    0x0A, 0,    0, 0,
};

const usbfs = ra8.periph.usbfs;
const run = exp.run;

fn enumerated() usbfs.host.Host {
    var script = usbfs.host.Host{};
    script.device = device;
    @memcpy(script.config[0..config.len], &config);
    script.config_len = config.len;
    script.step = .configured;
    return script;
}

test "no port asked for means nothing printed and nothing bound" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const script = enumerated();
    try run.afterRun(out.writer(), null, &script);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a device that never enumerated is reported, not served" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const script = usbfs.host.Host{};
    try run.afterRun(out.writer(), 1, &script);
    try std.testing.expectEqualStrings("usbip: the FS device never finished enumerating; nothing exported\n", out.items);
}

/// A host that imports 1-1 straight away.
fn importer(port: u16, status: *?u32) void {
    const address = std.net.Address.parseIp4("127.0.0.1", port) catch return;
    const stream = std.net.tcpConnectToAddress(address) catch return;
    defer stream.close();
    var header: [wire.op_header_len]u8 = undefined;
    (wire.OpHeader{ .code = wire.op.req_import }).encode(&header);
    var body = [_]u8{0} ** wire.busid_len;
    @memcpy(body[0..3], "1-1");
    stream.writeAll(&header) catch return;
    stream.writeAll(&body) catch return;
    var reply: [wire.op_header_len]u8 = undefined;
    stream.reader().readNoEof(&reply) catch return;
    status.* = (wire.OpHeader.decode(&reply) catch return).status;
}

test "an enumerated device is announced and handed to the importing host" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const script = enumerated();
    const item = (try exp.board.fsExport(&script)).?;
    var listener = try exp.listen.open(0);
    defer listener.deinit();
    var status: ?u32 = null;
    const thread = try std.Thread.spawn(.{}, importer, .{ exp.listen.port(&listener), &status });
    try run.offer(out.writer(), &listener, item);
    thread.join();
    try std.testing.expectEqual(@as(?u32, 0), status);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "usbip: exporting 1-1 (045b:5310) on 127.0.0.1:"));
    try std.testing.expect(std.mem.endsWith(u8, out.items, "usbip: a host imported 1-1; URB traffic is not routed yet\n"));
}
