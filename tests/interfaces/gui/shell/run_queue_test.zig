//! Tests for src/interfaces/gui/shell/run.zig under queue pressure: a full
//! request queue preserves Run and every owner until a slot frees, and a
//! disconnected send refuses and settles once at the last address.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Rig = @import("../local_rig.zig").Rig;
const Manual = @import("../manual_clock.zig").Manual;

const proto = ra8.rpc.session.rpc;
const shell_run = gui_app.shell.run;
const Run = shell_run.Run;
const Status = gui_app.status.bar.Status;

/// Blinks LED1 twice and then parks in a loop, so it never stops by itself.
const image = "tests/fixtures/gpio/blink.elf";
const slow: u64 = 1;

const Seen = struct { slices: u32 = 0, boundaries: u32 = 0, stops: u32 = 0 };

const Bench = struct {
    rig: Rig,
    status: Status = .{},
    clock: Manual = .{ .step_ns = 1000 },
    run: Run = .{},

    fn open(self: *Bench) !void {
        self.* = .{ .rig = undefined };
        try self.rig.open(image);
        errdefer self.rig.deinit();
        try self.rig.load(&self.status, image);
        self.run.start(self.status.run.halted.address);
    }
};

test "a full request queue preserves Run and every owner until a slot frees" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    const link = &bench.rig.link;
    var held: [proto.pending_slots]u32 = undefined;
    for (&held) |*id| id.* = try link.send(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    bench.run.frame(0, slow);
    const before = bench.run;
    for (0..3) |_| {
        try std.testing.expect(!bench.run.next(link, 0));
        try std.testing.expectEqualDeep(before, bench.run);
        try std.testing.expect(link.state == .connected);
    }
    try std.testing.expectError(error.TableFull, link.send(proto.Now, .now, .{ .core = .cpu0 }));

    // Real responses release capacity; no direct pending-table manipulation.
    try bench.rig.session.answer();
    const first = link.pump() orelse return error.NoAnswer;
    try std.testing.expect(first == .response and first.response.result == .ok);
    var answered: [proto.pending_slots]bool = @splat(false);
    const released = std.mem.indexOfScalar(u32, &held, first.response.id) orelse return error.WrongOwner;
    answered[released] = true;
    try std.testing.expectEqual(before.address, (try proto.decode(proto.U32, first.response.result.ok)).value);
    try std.testing.expectEqual(shell_run.Seen.other, bench.run.observe(first, 0));
    try std.testing.expectEqualDeep(before, bench.run);

    try std.testing.expect(bench.run.next(link, 0));
    const slice = bench.run.slice_id.?;
    try std.testing.expect(std.mem.indexOfScalar(u32, &held, slice) == null);
    try std.testing.expect(!bench.run.next(link, 0));
    try std.testing.expectEqual(@as(u32, 1), bench.run.sent);
    try std.testing.expectError(error.TableFull, link.send(proto.Now, .now, .{ .core = .cpu0 }));
    try bench.rig.session.answer();
    var seen: Seen = .{};
    while (link.pump()) |arrival| switch (bench.run.observe(arrival, 0)) {
        .slice => seen.slices += 1,
        .boundary => seen.boundaries += 1,
        .other => {
            try std.testing.expect(arrival == .response and arrival.response.result == .ok);
            const at = std.mem.indexOfScalar(u32, &held, arrival.response.id) orelse return error.WrongOwner;
            try std.testing.expect(!answered[at]);
            answered[at] = true;
            try std.testing.expectEqual(before.address, (try proto.decode(proto.U32, arrival.response.result.ok)).value);
        },
    };
    for (answered) |got| try std.testing.expect(got);
    try std.testing.expectEqual(Seen{ .slices = 1, .boundaries = 1 }, seen);
    try std.testing.expect(bench.run.lit and !bench.run.refused);
    try std.testing.expectEqual(@as(?u32, null), bench.run.slice_id);
    try std.testing.expectEqual(@as(?u32, null), bench.run.halted());
    try std.testing.expectEqual(try bench.rig.pc(.cpu0), bench.run.address);
}

test "a disconnected slice send still refuses and settles once at the last address" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    const at = bench.run.address;
    bench.run.frame(0, slow);
    bench.rig.link.close();
    try std.testing.expect(!bench.run.next(&bench.rig.link, 0));
    try std.testing.expect(!bench.run.lit and bench.run.refused);
    try std.testing.expectEqual(@as(?u32, null), bench.run.slice_id);
    try std.testing.expectEqual(@as(u32, 0), bench.run.sent);
    try std.testing.expectEqual(@as(?u32, at), bench.run.halted());
    try std.testing.expectEqual(@as(?u32, null), bench.run.halted());
}
