//! The navigation index is fed by the served run: round boundaries become
//! iterations, and a ThreadX image's thread switches and exception entries
//! and returns are stamped with their positions, so `nav` queries and the
//! `rtos`, `isr` and `iter` seek steps answer from a real run.
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const nav_handlers = ra8.rpc.session.nav_handlers;
const transport = ra8.session.transport;

const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 1_000_000;
        return self.now_ns;
    }
    fn wall(self: *FakeWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

fn seek(served: *setup.Served, text: []const u8) !void {
    var wall = FakeWall{};
    const t = served.owner.transport();
    const ticket = try t.command(.{ .seek = .{ .target = text } });
    _ = try t.finish(ticket, wall.wall(), null);
}

test "round boundaries of a served run are indexed as iterations" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, "tests/fixtures/dfu/dfu_bootloader.elf", null, .{ .root = root, .checkpoint_every = 16 });
    defer served.deinit();
    const session = served.owner.session();
    _ = try session.run(.cpu0, .run);
    const nav = served.nav.?;
    try std.testing.expect(nav.iterationCount() > 2);
    try std.testing.expect(nav.getIterationSlots(nav.iterationCount()).? > 0);

    // Stepping back one boundary lands on the previous iteration's position.
    const last = nav.getIteration(nav.iterationCount()).?;
    const query = nav_handlers.navQuery(&served.context, .{ .kind = .iteration, .index = nav.iterationCount() });
    try std.testing.expectEqual(last.r, query.ok.r);
    try seek(&served, "iter prev");
    const landed = session.currentPosition();
    try std.testing.expect(landed.r < last.r or landed.r == last.r);
}

test "a ThreadX run indexes its thread switches and exceptions with positions" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, "tests/fixtures/threadx/threadx_stkof.elf", null, .{ .root = root, .checkpoint_every = 16 });
    defer served.deinit();
    const session = served.owner.session();
    _ = try session.run(.cpu0, .run);
    const nav = served.nav.?;
    try std.testing.expect(nav.rtosSwitchCount() > 0);
    try std.testing.expect(nav.isrTransitionCount() > 0);
    const rtos = nav_handlers.navQuery(&served.context, .{ .kind = .rtos });
    try std.testing.expectEqual(@as(u64, nav.rtosSwitchCount()), rtos.ok.count);
    const isr = nav_handlers.navQuery(&served.context, .{ .kind = .isr });
    try std.testing.expectEqual(@as(u64, nav.isrTransitionCount()), isr.ok.count);

    // The latest switch is a position the machine lands on exactly.
    const before = session.currentPosition();
    const newest = nav.rtos_switches.items[nav.rtos_switches.items.len - 1].position;
    try seek(&served, "rtos prev");
    const landed = session.currentPosition();
    try std.testing.expectEqual(std.math.Order.lt, try session.comparePositions(landed, before));
    try std.testing.expectEqual(newest, landed);
    const isr_at = nav.prevIsr(landed, null, null).?;
    try seek(&served, "isr prev");
    try std.testing.expectEqual(isr_at, session.currentPosition());
}
