//! QTR-003 COMMON qualification tests: C6 network/DNS bridge (`recorded_c6`)
//! and loopback USB/IP (`recorded_usbip`) record once and replay twice
//! identically with zero live sockets/polls, plus past-cursor `AsyncQueue` hold
//! and replay host hangup.
const std = @import("std");
const ra8 = @import("ra8");
const oracle = @import("common_oracle.zig");
const fixture = @import("../fork_fixture.zig");
const usb_rig = @import("../board/recorded_usbip_rig.zig");

const api = ra8.session.api;
const feeder = ra8.session.history_replay_feeder;
const async_queue = ra8.session.history_async_queue;
const async_traffic = ra8.session.history_async_traffic;
const recorded_c6 = ra8.session.board.recorded_c6;
const recorded_usbip = ra8.session.board.recorded_usbip;
const hosted = ra8.components.esp_hosted;

fn sessionMuted(ctx: *anyopaque) bool {
    const sess: *api.Session = @ptrCast(@alignCast(ctx));
    return sess.outputMuted();
}

const C6NetHost = struct {
    var opens: u32 = 0;
    var sends: u32 = 0;
    var recvs: u32 = 0;
    var ready: bool = false;
    var delivered: bool = false;

    fn reset() void {
        opens = 0;
        sends = 0;
        recvs = 0;
        ready = false;
        delivered = false;
    }
    fn open(_: hosted.host_net.Kind) anyerror!hosted.host_net.Handle {
        opens += 1;
        return @fromBackingInt(@intCast(11));
    }
    fn connect(_: hosted.host_net.Handle, _: hosted.host_net.Address) anyerror!hosted.host_net.Connect {
        return .done;
    }
    fn writable(_: hosted.host_net.Handle) anyerror!bool {
        return true;
    }
    fn finished(_: hosted.host_net.Handle) anyerror!void {}
    fn send(_: hosted.host_net.Handle, b: []const u8) anyerror!usize {
        sends += 1;
        return b.len;
    }
    fn recv(_: hosted.host_net.Handle, out: []u8, _: hosted.host_net.Receive) anyerror!usize {
        recvs += 1;
        if (!ready or delivered) return error.WouldBlock;
        delivered = true;
        @memcpy(out[0..8], "c6-reply");
        return 8;
    }
    fn shutdownSend(_: hosted.host_net.Handle) anyerror!void {}
    fn close(_: hosted.host_net.Handle) void {}

    const net: hosted.host_net.Net = .{
        .open = open,
        .connect = connect,
        .writable = writable,
        .finished = finished,
        .send = send,
        .recv = recv,
        .shutdownSend = shutdownSend,
        .close = close,
    };
};

fn runC6Exchange(bridge: *hosted.net.Bridge, h: *fixture.MockHarness, stream: *oracle.Stream) !void {
    const route = hosted.eth.Route{
        .src_mac = hosted.station.mac,
        .dst_mac = hosted.station.bssid,
        .src_ip = hosted.dhcp.lease_ip,
        .dst_ip = hosted.dhcp.server_ip,
        .src_port = 41000,
        .dst_port = 8080,
    };
    var queue: hosted.queue.Queue = .{};
    var buf: [hosted.frame.max_payload]u8 = undefined;
    var raw: [hosted.frame.frame_size]u8 = undefined;
    for (1..7) |r| {
        h.grid_state.at.r = @intCast(r);
        switch (r) {
            1 => {
                const n = hosted.eth.tcpFrame(&buf, route, 500, 0, hosted.eth.TcpFlag.syn, 1460, &.{}).?;
                _ = bridge.forward(&queue, buf[0..n]);
            },
            2 => {
                const n = hosted.eth.tcpFrame(&buf, route, 501, 0xC6000001, hosted.eth.TcpFlag.psh | hosted.eth.TcpFlag.ack, 1460, "get").?;
                _ = bridge.forward(&queue, buf[0..n]);
            },
            4 => C6NetHost.ready = true,
            else => {},
        }
        bridge.poll(&queue);
        while (queue.pop(&raw)) {
            const parsed = try hosted.frame.parse(&raw);
            stream.append(6, h.grid_state.at, r * 1_000, parsed.payload);
        }
    }
}

fn verifyC6AndUsbipReplayOnce(
    gpa: std.mem.Allocator,
    s: *usb_rig.Setup,
    log: []const u8,
    live_c6_digest: oracle.Digest,
    live_usb_digest: u64,
) !void {
    C6NetHost.reset();
    s.h.grid_state.at.r = 0;
    try feeder.loadSessionInterventions(&s.h.session, log, .at);
    defer feeder.release(&s.h.session);
    s.h.session.setReplaying(true);
    defer s.h.session.setReplaying(false);

    var rep_bridge: hosted.net.Bridge = .{ .net = C6NetHost.net, .hold = .{ .context = &s.h.session, .heldFn = sessionMuted } };
    try recorded_c6.attach(gpa, &s.h.session, &rep_bridge);
    var rep_c6_stream: oracle.Stream = .{};
    try runC6Exchange(&rep_bridge, s.h, &rep_c6_stream);
    try std.testing.expectEqual(@as(u32, 0), C6NetHost.opens);
    try std.testing.expectEqual(@as(u32, 0), C6NetHost.sends);
    try std.testing.expectEqual(@as(u32, 0), C6NetHost.recvs);
    try std.testing.expectEqual(live_c6_digest, rep_c6_stream.digest());
    recorded_c6.release(&rep_bridge);

    var tripwire_usb: usb_rig.Host = .{};
    var rep_usb: usb_rig.Run = .{};
    tripwire_usb.install(&rep_usb.target);
    try recorded_usbip.attach(gpa, &s.h.session, &rep_usb.target);
    try std.testing.expectEqual(live_usb_digest, rep_usb.go(s.h, 14));
    try std.testing.expectEqual(@as(u32, 0), tripwire_usb.polls);
    recorded_usbip.release(&rep_usb.target, &s.h.session);
}

test "COMMON QTR-003: C6 network bridge and loopback USB/IP record once and replay twice with past-cursor hold" {
    const gpa = std.testing.allocator;
    const s = try usb_rig.Setup.open();
    defer s.close();

    C6NetHost.reset();
    var live_bridge: hosted.net.Bridge = .{ .net = C6NetHost.net, .hold = .{ .context = &s.h.session, .heldFn = sessionMuted } };
    try recorded_c6.attach(gpa, &s.h.session, &live_bridge);
    var live_c6_stream: oracle.Stream = .{};
    try runC6Exchange(&live_bridge, s.h, &live_c6_stream);
    try std.testing.expectEqual(@as(u32, 1), C6NetHost.opens);
    try std.testing.expect(live_c6_stream.count > 0);
    recorded_c6.release(&live_bridge);

    var live_usb_host: usb_rig.Host = .{};
    var live_usb: usb_rig.Run = .{};
    live_usb_host.install(&live_usb.target);
    try recorded_usbip.attach(gpa, &s.h.session, &live_usb.target);
    const live_usb_digest = live_usb.go(s.h, 14);
    try std.testing.expectEqual(@as(u32, 14), live_usb_host.polls);
    recorded_usbip.release(&live_usb.target, &s.h.session);

    try s.h.recorder.commit(1);
    const log = s.h.mock_storage.bytes.items;
    const log_len = log.len;

    for (0..2) |_| {
        try verifyC6AndUsbipReplayOnce(gpa, s, log, live_c6_stream.digest(), live_usb_digest);
    }
    try s.h.recorder.commit(2);
    try std.testing.expectEqual(log_len, s.h.mock_storage.bytes.items.len);

    // Past-cursor async queue hold + drain without fork, plus replay host hangup.
    s.h.session.attachAsyncQueue(async_queue.AsyncQueue.init(gpa, 64 * 1024));
    var end = s.h.graph.get(0).?.recorded_end;
    end.r = 50;
    try s.h.graph.insertNode(.{ .id = 0, .parent = 0, .fork_at = .{}, .reason = .base, .recorded_end = end });

    var async_host: usb_rig.Host = .{};
    var async_run: usb_rig.Run = .{};
    async_host.install(&async_run.target);
    try recorded_usbip.attach(gpa, &s.h.session, &async_run.target);
    defer recorded_usbip.release(&async_run.target, &s.h.session);

    s.h.grid_state.at.r = 10;
    async_host.say(.{ .kind = .import, .head = "1-1" });
    try std.testing.expectEqual(@as(usize, 1), s.h.session.async_traffic.queue.?.count());
    s.h.grid_state.at.r = 50;
    try std.testing.expectEqual(@as(usize, 1), try async_traffic.drainIfNeeded(&s.h.session));
    try std.testing.expectEqual(@as(u32, 0), s.h.router.active_line);
}
