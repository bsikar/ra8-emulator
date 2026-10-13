//! RA8EMU-687: the ESP32-C6 saved mid-exchange and loaded into a fresh one
//! matches byte for byte and keeps the fresh one's own pins.
const std = @import("std");
const ra8 = @import("ra8");
const esp_hosted = ra8.components.esp_hosted;
const gpio = ra8.chip.periph.gpio;
const file = ra8.snapshot.file;
const section = ra8.components.esp_hosted.snapshot;

const Stand = struct { c6: esp_hosted.C6 };

fn fresh() Stand {
    var board: Stand = .{ .c6 = .{} };
    @memset(&board.c6.wire.rx, 0);
    @memset(&board.c6.wire.tx, 0);
    for (&board.c6.wire.queue.slots) |*slot| @memset(slot, 0);
    return board;
}

fn fill(board: *Stand) void {
    board.c6.reply = .{0x5A};
    board.c6.wire.rx[0] = 0x01;
    board.c6.wire.tx[2] = 0x7E;
    board.c6.wire.offset = 9;
    board.c6.wire.caps_seen = true;
    board.c6.wire.caps_len = 3;
    board.c6.wire.caps[1] = 0x44;
    board.c6.wire.boot_queued = true;
    board.c6.wire.boots_sent = 2;
    board.c6.wire.queue.slots[1][0] = 0x33;
    board.c6.wire.queue.head = 1;
    board.c6.wire.queue.len = 1;
    board.c6.wire.replies_sent = 6;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try section.save(board, &list.writer);
}

test "a C6 mid-exchange round-trips byte for byte" {
    var board = fresh();
    fill(&board);
    var first = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first.deinit();
    try saved(&board, &first);

    var target = fresh();
    try section.load(&target, first.written());
    var second = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second.deinit();
    try saved(&target, &second);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
    try std.testing.expectEqual(@as(u8, 0x33), target.c6.wire.queue.slots[1][0]);
    try std.testing.expectEqual(@as(u32, 6), target.c6.wire.replies_sent);
}

test "the target keeps its own pins and a bad queue is refused" {
    var board = fresh();
    fill(&board);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&board, &bytes);

    var pins: gpio.Gpio = undefined;
    var target = fresh();
    target.c6.pins = &pins;
    try section.load(&target, bytes.written());
    try std.testing.expect(target.c6.pins == &pins);

    board.c6.wire.queue.len = board.c6.wire.queue.slots.len + 1;
    bytes.clearRetainingCapacity();
    try saved(&board, &bytes);
    var other = fresh();
    try std.testing.expectError(error.BadValue, section.load(&other, bytes.written()));
    try std.testing.expectEqual(@as(u32, 0), other.c6.wire.replies_sent);
}

test "a missing or short section leaves the C6 alone" {
    var header = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer header.deinit();
    try file.writeHeader(&header.writer);
    var target = fresh();
    try std.testing.expectError(error.Missing, section.load(&target, header.written()));

    var board = fresh();
    fill(&board);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&board, &bytes);
    try std.testing.expect(std.meta.isError(section.load(&target, bytes.written()[0 .. bytes.written().len - 3])));
    try std.testing.expectEqual(@as(u32, 0), target.c6.wire.boots_sent);
}

fn fakeLookup(_: ?*anyopaque, _: ?std.Io, _: []const u8, _: *[esp_hosted.dns.max_answers][4]u8) !u8 {
    return 0;
}

test "snapshot failure and success preserve host resolver wiring" {
    var board = fresh();
    fill(&board);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&board, &bytes);

    var target = fresh();
    target.c6.wire.bridge.resolver.lookupFn = fakeLookup;
    try std.testing.expect(std.meta.isError(section.load(&target, bytes.written()[0 .. bytes.written().len - 1])));
    try std.testing.expect(target.c6.wire.bridge.resolver.lookupFn == fakeLookup);
    try section.load(&target, bytes.written());
    try std.testing.expect(target.c6.wire.bridge.resolver.lookupFn == fakeLookup);
}

const Lifecycle = struct {
    var sockets_closed: usize = 0;
    var jobs_detached: usize = 0;
    var roots_released: usize = 0;

    fn close(_: esp_hosted.host_net.Handle) void {
        sockets_closed += 1;
    }
    fn spawn(_: *const fn (*anyopaque) void, _: *anyopaque) !esp_hosted.worker.Handle {
        return error.UnexpectedSpawn;
    }
    fn join(_: esp_hosted.worker.Handle) void {
        @panic("unexpected join");
    }
    fn detach(_: esp_hosted.worker.Handle) void {
        jobs_detached += 1;
    }
    fn create(_: esp_hosted.tape.Handle, _: []const u8) !esp_hosted.tape.Handle {
        return error.UnexpectedCreate;
    }
    fn append(_: esp_hosted.tape.Handle, _: []const u8) !void {
        return error.UnexpectedAppend;
    }
    fn closeTape(_: esp_hosted.tape.Handle) void {
        @panic("unexpected tape close");
    }
    fn readAlloc(_: esp_hosted.tape.Handle, _: []const u8, _: std.mem.Allocator, _: usize) ![]u8 {
        return error.UnexpectedRead;
    }
    fn readInto(_: esp_hosted.tape.Handle, _: []const u8, _: []u8) ![]u8 {
        return error.UnexpectedRead;
    }
    fn release(_: esp_hosted.tape.Handle) void {
        roots_released += 1;
    }
};

test "state strict C6 closes old TCP UDP DNS only after success and retains all host attachments" {
    Lifecycle.sockets_closed = 0;
    Lifecycle.jobs_detached = 0;
    Lifecycle.roots_released = 0;
    var source = fresh();
    fill(&source);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&source, &bytes);
    var target = fresh();
    defer target.c6.deinit();
    const bridge = &target.c6.wire.bridge;
    var context: u8 = 0;
    bridge.resolver = .{ .context = &context, .io = std.testing.io, .lookupFn = fakeLookup };
    var net = esp_hosted.host_net.Net.of(ra8.host.sock);
    net.close = Lifecycle.close;
    bridge.net = net;
    bridge.worker = .{ .spawn = Lifecycle.spawn, .join = Lifecycle.join, .detach = Lifecycle.detach };
    bridge.tape = .init(.record, .{
        .root = @fromBackingInt(33),
        .create = Lifecycle.create,
        .append = Lifecycle.append,
        .close = Lifecycle.closeTape,
        .readAlloc = Lifecycle.readAlloc,
        .readInto = Lifecycle.readInto,
        .release = Lifecycle.release,
    });
    bridge.tape.key_len = 1;
    bridge.tape.keys[0] = .{ .proto = .tcp, .ip = .{ 127, 0, 0, 1 }, .port = 80 };
    bridge.tape.counts[0] = 4;
    bridge.tape.misses.store(7, .release);
    bridge.tcp_flows[0].state = .established;
    bridge.tcp_flows[0].sock = .{ .net = net, .socket = @fromBackingInt(1) };
    bridge.udp_bridge.flows[0].used = true;
    bridge.udp_bridge.flows[0].sock = .{ .net = net, .socket = @fromBackingInt(2) };
    bridge.dns_bridge.start(&.{}, .{
        .src_mac = @splat(0),
        .dst_mac = @splat(0),
        .src_ip = @splat(0),
        .dst_ip = @splat(0),
        .src_port = 1,
        .dst_port = 53,
    }, bridge.resolver, null);
    bridge.dns_bridge.thread = @fromBackingInt(3);
    bridge.dns_bridge.worker = bridge.worker;
    try std.testing.expect(bridge.active());
    try std.testing.expect(std.meta.isError(section.load(&target, bytes.written()[0 .. bytes.written().len - 1])));
    try std.testing.expect(bridge.active());
    try std.testing.expectEqual(@as(usize, 0), Lifecycle.sockets_closed);
    try std.testing.expectEqual(@as(usize, 0), Lifecycle.jobs_detached);
    try section.load(&target, bytes.written());
    try std.testing.expect(!bridge.active());
    try std.testing.expectEqual(@as(usize, 2), Lifecycle.sockets_closed);
    try std.testing.expectEqual(@as(usize, 1), Lifecycle.jobs_detached);
    try std.testing.expectEqual(@as(usize, 0), Lifecycle.roots_released);
    try std.testing.expect(bridge.resolver.context == @as(?*anyopaque, @ptrCast(&context)) and bridge.resolver.io != null);
    try std.testing.expect(bridge.resolver.lookupFn == fakeLookup);
    try std.testing.expect(bridge.net.?.close == Lifecycle.close and bridge.worker.?.spawn == Lifecycle.spawn);
    try std.testing.expectEqual(esp_hosted.tape.Mode.record, bridge.tape.mode);
    try std.testing.expectEqual(@as(usize, 33), @backingInt(bridge.tape.store.?.root));
    try std.testing.expectEqual(@as(usize, 1), bridge.tape.key_len);
    try std.testing.expectEqual(@as(u32, 4), bridge.tape.counts[0]);
    try std.testing.expectEqual(@as(u32, 7), bridge.tape.missed());
}
