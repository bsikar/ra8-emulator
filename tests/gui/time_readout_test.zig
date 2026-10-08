//! Host tests for the time bar's clock readout (RA8EMU-806): the achieved
//! speed and when it shows, the line it reads, and the readout following a
//! spawned `serve --stdio` session's virtual time across a run.
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const proto = ra8.interfaces.rpc.session;
const session_link = ra8.gui.session_link;
const time_readout = ra8.gui.time_readout;
const Link = session_link.Link;
const Readout = time_readout.Readout;
const Status = ra8.gui.status_bar.Status;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/fpu/fp_basic.elf";

test "the achieved speed shows only when short of the request, never for max" {
    const from: time_readout.Sample = .{ .wall_ns = 1_000_000_000, .virtual_ns = 0 };
    const to: time_readout.Sample = .{ .wall_ns = 2_000_000_000, .virtual_ns = 420_000_000 };
    try std.testing.expectEqual(@as(?u64, 420), time_readout.achieved(from, to));
    try std.testing.expectEqual(@as(?u64, null), time_readout.achieved(to, from));
    try std.testing.expect(time_readout.short(420, 1000));
    try std.testing.expect(!time_readout.short(960, 1000));
    try std.testing.expect(!time_readout.short(1, 0));

    var buf: [96]u8 = undefined;
    var readout: Readout = .{};
    try std.testing.expectEqualStrings("T+--", try readout.text(1000, &buf));
    readout.virtual_ns = 3_723_456_000_000;
    readout.achieved_milli = 420;
    try std.testing.expectEqualStrings("T+1:02:03.456 | 0.42x of 1x", try readout.text(1000, &buf));
    try std.testing.expectEqualStrings("T+1:02:03.456", try readout.text(0, &buf));
}

fn connect(link: *Link) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (link.state == .connecting and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

fn busy(readout: *const Readout, status: *const Status) bool {
    return readout.now_id != null or status.load_id != null or status.pc_id != null or status.run == .running;
}

/// Pump the link into the readout and the status until nothing is
/// outstanding, for ten seconds.
fn settle(link: *Link, readout: *Readout, status: *Status) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (busy(readout, status)) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() > deadline) return error.Timeout;
        if (link.state != .connected) return error.LinkLost;
        const arrival = link.pump() orelse {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        readout.observe(arrival, @intCast(std.Io.Timestamp.now(std.testing.io, .awake).toNanoseconds()));
        status.observe(link, arrival);
    }
}

test "the readout follows a local session's virtual time across a run" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, elf_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    try connect(&link);

    var readout: Readout = .{};
    var status: Status = .{};
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, elf_path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    try status.load(&link, elf_path, bytes);
    try readout.poll(&link);
    try settle(&link, &readout, &status);
    const before = readout.virtual_ns orelse return error.NoTime;

    try status.go(&link, .cont, 200_000);
    try settle(&link, &readout, &status);
    try readout.poll(&link);
    try settle(&link, &readout, &status);
    try std.testing.expect(readout.virtual_ns.? > before);

    var buf: [96]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try readout.text(1000, &buf), "T+"));

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
