//! Tests for src/board/usb/usb.zig: the scripted host on the device jack and the
//! USBFS interrupt the board raises for it.
const std = @import("std");
const ra8 = @import("ra8");

const usb = ra8.board.usb;
const usbfs = ra8.chip.periph.usbfs;
const regs = ra8.chip.periph.usbhs.regs;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

fn pulledUp() usb.Usb {
    var board = usb.Usb{};
    board.device.connectVbus();
    board.device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    board.device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.dvst | usbfs.intsts0.vbint));
    return board;
}

test "no event while nothing is enabled" {
    var board = pulledUp();
    board.tick();
    board.tick();
    try std.testing.expectEqual(@as(usize, 0), board.dueEvents().len);
}

test "the host's first SETUP raises USBFS_INT once CTRE is enabled" {
    var board = pulledUp();
    board.device.write(at(regs.reg.intenb0), 2, usbfs.intsts0.ctrt);
    board.tick();
    board.tick();
    try std.testing.expectEqual(usbfs.host.Step.device_descriptor, board.script.step);
    const due = board.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(usb.event.usbfs_int, due.get(0));
}

test "the line drops once the driver clears the cause" {
    var board = pulledUp();
    board.device.write(at(regs.reg.intenb0), 2, usbfs.intsts0.ctrt);
    board.tick();
    board.tick();
    board.device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.ctrt));
    try std.testing.expectEqual(@as(usize, 0), board.dueEvents().len);
}

test "a disabled status bit raises nothing" {
    var board = pulledUp();
    board.device.write(at(regs.reg.intenb0), 2, usbfs.intsts0.vbint);
    board.tick();
    board.tick();
    try std.testing.expectEqual(@as(usize, 0), board.dueEvents().len);
}

test "loopBack cables the HS host to the board's own FS device" {
    var board = pulledUp();
    try std.testing.expect(board.cable == null);
    board.loopBack();
    const far = board.host.xfer.far orelse return error.NoCable;
    try std.testing.expectEqual(&board.device, board.cable.?.device);
    try std.testing.expectEqual(@as(*anyopaque, &board.cable.?), far.context);
}

test "with the cable in, the scripted host stays off the device jack" {
    var cabled = pulledUp();
    cabled.loopBack();
    var scripted = pulledUp();
    var step: u32 = 0;
    while (step < 64) : (step += 1) {
        cabled.tick();
        scripted.tick();
    }
    try std.testing.expectEqualDeep(usbfs.host.Host{}, cabled.script);
    try std.testing.expect(!std.meta.eql(usbfs.host.Host{}, scripted.script));
}

fn bridgeHook() usb.Hook {
    const Watch = struct {
        fn poll(_: *anyopaque, _: *usbfs.Device, _: *const usbfs.host.Host) void {}
    };
    var seen: u8 = 0;
    return .{ .context = &seen, .pollFn = Watch.poll };
}

test "the device jack's enumeration holds the width" {
    // Waiting with nothing the line can offer: nothing could advance it.
    var idle = usb.Usb{};
    idle.device.connectVbus();
    try std.testing.expect(idle.quiet());
    // The pull-up lands: the next boundary could advance the script.
    try std.testing.expect(!pulledUp().quiet());
    // A step in flight moves one step per boundary.
    var in_flight = pulledUp();
    in_flight.tick();
    try std.testing.expectEqual(usbfs.host.Step.device_descriptor, in_flight.script.step);
    try std.testing.expect(!in_flight.quiet());
}

test "the device jack's settled script is quiet" {
    var done = pulledUp();
    done.script.step = .configured;
    try std.testing.expect(done.quiet());
    var refused = pulledUp();
    refused.script.step = .failed;
    try std.testing.expect(refused.quiet());
}

test "the device jack's failed script is quiet" {
    var board = pulledUp();
    board.script.patience = 1;
    var tick: u32 = 0;
    while (tick < 5 and board.script.step != .failed) : (tick += 1) board.tick();
    try std.testing.expectEqual(usbfs.host.Step.failed, board.script.step);
    try std.testing.expect(board.quiet());
}

test "the device jack's live bridge keeps the width" {
    var idle = usb.Usb{};
    idle.device.connectVbus();
    idle.bridge = bridgeHook();
    // Nothing attached: the bridge has nothing to poll.
    try std.testing.expect(idle.quiet());
    // The line comes up: the bridge polls it every boundary.
    var live = pulledUp();
    live.bridge = bridgeHook();
    try std.testing.expect(!live.quiet());
}

test "the device jack under the loop cable holds no width" {
    var cabled = pulledUp();
    cabled.loopBack();
    // The scripted host is frozen in .waiting while the line reads Default.
    try std.testing.expect(!cabled.quiet());
    // Once the HS host has the device addressed, the waiting script is idle.
    cabled.device.setup(usbfs.host.requests.set_address);
    try std.testing.expect(cabled.quiet());
}
