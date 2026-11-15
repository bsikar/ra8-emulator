//! Confirmed native recovery, refusal, and connection/request ownership.
const std = @import("std");
const ra8 = @import("ra8");
const gui = @import("gui_app");
const Rig = @import("../local_rig.zig").Rig;
const proto = ra8.rpc.session.rpc;
const Shell = gui.shell.loop.Shell;
const Arrival = gui.session_link.Arrival;
const image = "tests/fixtures/gpio/blink.elf";

const Bench = struct {
    rig: Rig,
    shell: Shell,

    fn open(self: *Bench) !void {
        self.* = .{ .rig = undefined, .shell = undefined };
        try self.rig.openPlain(image);
        errdefer self.rig.deinit();
        self.shell = Shell.init(std.testing.allocator, try gui.pane_layout.twoCore(std.testing.allocator));
        self.shell.timeline.?.deinit();
        self.shell.timeline = null;
        self.shell.loaded = true;
        self.shell.link = &self.rig.link;
        self.shell.status.run = .{ .halted = .{ .address = 0, .reason = null } };
    }

    fn deinit(self: *Bench) void {
        self.shell.deinit();
        self.rig.deinit();
    }

    fn answer(self: *Bench) !bool {
        try self.rig.answer();
        var restored = false;
        while (self.rig.link.pump()) |arrival| restored = self.shell.recovery.observe(&self.shell, arrival) or restored;
        return restored;
    }
};

fn response(bench: *Bench, payload: []const u8) Arrival {
    const asked = bench.shell.recovery.asked.?;
    return .{ .response = .{ .id = asked.id, .connection = asked.connection, .result = .{ .ok = payload } } };
}

test "native undo and reset wait for real acceptance and restore the requested state" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    const session = bench.rig.session.setup.owner.session();
    const initial = try session.register(.cpu0, .r0);
    try session.setRegister(.cpu0, .r0, 0x1234);
    bench.shell.recovery.ask(&bench.shell, .undo_write);
    const asked = bench.shell.recovery.asked.?;
    bench.shell.recovery.ask(&bench.shell, .reset_image);
    try std.testing.expectEqual(asked.id, bench.shell.recovery.asked.?.id);
    try std.testing.expectEqual(@as(u32, 0x1234), try session.register(.cpu0, .r0));
    try std.testing.expect(bench.shell.status.run == .halted);
    try std.testing.expectEqual(@as(?u32, null), bench.shell.status.pc_id);
    try std.testing.expect(try bench.answer());
    try std.testing.expectEqual(initial, try session.register(.cpu0, .r0));
    try std.testing.expect(bench.shell.recovery.asked == null);
    try std.testing.expect(bench.shell.status.pc_id != null);
    try std.testing.expectEqual(@as(?gui.status.bar.Refusal, null), bench.shell.status.refused);
    try session.setRegister(.cpu0, .r0, 0x5678);
    bench.shell.recovery.ask(&bench.shell, .reset_image);
    try std.testing.expect(try bench.answer());
    try std.testing.expectEqual(initial, try session.register(.cpu0, .r0));
    try std.testing.expectError(error.NoUndo, session.undoWrite());
}

test "a native refusal leaves the shown state intact and releases the pending action" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    bench.shell.recovery.ask(&bench.shell, .undo_write);
    try std.testing.expect(!try bench.answer());
    try std.testing.expectEqual(gui.status.bar.Refusal.undo, bench.shell.status.refused.?);
    try std.testing.expect(bench.shell.status.run == .halted);
    try std.testing.expect(bench.shell.recovery.asked == null);
    try std.testing.expectEqual(@as(?u32, null), bench.shell.status.pc_id);
}

test "recovery rejects zero malformed and noncanonical acknowledgements without refreshing" {
    for ([_][]const u8{ &.{0}, "", &.{2}, &.{ 1, 0 } }) |payload| {
        var bench: Bench = undefined;
        try bench.open();
        defer bench.deinit();
        bench.shell.recovery.ask(&bench.shell, .reset_image);
        try std.testing.expect(!bench.shell.recovery.observe(&bench.shell, response(&bench, payload)));
        try std.testing.expectEqual(gui.status.bar.Refusal.reset_image, bench.shell.status.refused.?);
        try std.testing.expect(bench.shell.status.run == .halted);
        try std.testing.expect(bench.shell.recovery.asked == null);
        try std.testing.expectEqual(@as(?u32, null), bench.shell.status.pc_id);
    }
}

test "failure disconnection and image loading clear pending recovery without an arrival" {
    for (0..4) |change| {
        var bench: Bench = undefined;
        try bench.open();
        defer bench.deinit();
        bench.shell.recovery.ask(&bench.shell, .reset_image);
        try std.testing.expect(bench.shell.recovery.asked != null);
        switch (change) {
            0 => bench.rig.link.state = .{ .failed = .ended },
            1 => bench.shell.link = null,
            2 => bench.shell.status.load_id = 99,
            else => bench.shell.loaded = false,
        }
        try std.testing.expect(!bench.shell.recovery.pending(&bench.shell));
        try std.testing.expect(bench.shell.status.run == .halted);
    }
}

test "reopening the same Link cannot accept an old acknowledgement with a reused id" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    bench.shell.recovery.ask(&bench.shell, .reset_image);
    const old = response(&bench, &.{1});
    var replacement: Rig = undefined;
    try replacement.openPlain(image);
    defer replacement.deinit();
    bench.rig.link.openNativePlain(&replacement.worker.native);
    try std.testing.expect(!bench.shell.recovery.pending(&bench.shell));
    bench.shell.recovery.ask(&bench.shell, .reset_image);
    const fresh = bench.shell.recovery.asked.?;
    try std.testing.expectEqual(old.response.id, fresh.id);
    try std.testing.expect(old.response.connection != fresh.connection);
    try std.testing.expect(!bench.shell.recovery.observe(&bench.shell, old));
    try std.testing.expect(bench.shell.recovery.asked != null);
    _ = try replacement.worker.native.serve();
    var restored = false;
    while (bench.rig.link.pump()) |arrival| restored = bench.shell.recovery.observe(&bench.shell, arrival) or restored;
    try std.testing.expect(restored);
}

test "loading running and unsupported sessions never enqueue recovery" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    bench.shell.status.load_id = 17;
    bench.shell.recovery.ask(&bench.shell, .reset_image);
    try std.testing.expect(bench.shell.recovery.asked == null);
    bench.shell.status.load_id = null;
    bench.shell.status.run = .running;
    bench.shell.recovery.ask(&bench.shell, .undo_write);
    try std.testing.expect(bench.shell.recovery.asked == null);
    bench.shell.status.run = .unknown;
    bench.rig.link.state.connected.caps &= ~proto.recovery_cap;
    bench.shell.recovery.ask(&bench.shell, .undo_write);
    try std.testing.expectEqual(gui.status.bar.Refusal.undo, bench.shell.status.refused.?);
    try std.testing.expectEqual(@as(usize, 0), bench.rig.worker.native.count);
}

test "the shell refreshes both cores only after confirmed recovery" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    var registers: gui.shell.registers.Pair = .{};
    var memory: gui.shell.memory.Pair = .{};
    var code: gui.shell.memory.Pair = .{ .follows = .pc };
    var stack: gui.shell.stack.Pair = .{};
    var source = gui.shell.source.Pair.init(std.testing.io);
    var locals: gui.shell.locals.Pair = .{};
    for (0..2) |i| {
        registers.cores[i].now = .{};
        memory.cores[i].now = .{};
        code.cores[i].now = .{};
        stack.cores[i].now = .{};
        source.cores[i].now = .{};
        locals.cores[i].now = .{};
    }
    bench.shell.registers = &registers;
    bench.shell.memory = &memory;
    bench.shell.code = &code;
    bench.shell.stack = &stack;
    bench.shell.source = &source;
    bench.shell.locals = &locals;
    try bench.rig.session.setup.owner.session().setRegister(.cpu0, .r0, 99);
    bench.shell.recovery.ask(&bench.shell, .undo_write);
    try bench.shell.pump();
    try std.testing.expect(registers.cores[0].now != null and memory.cores[0].now != null);
    try bench.rig.answer();
    try bench.shell.pump();
    for (0..2) |i| {
        try std.testing.expect(registers.cores[i].now == null and registers.cores[i].want);
        try std.testing.expect(memory.cores[i].now == null and memory.cores[i].want);
        try std.testing.expect(code.cores[i].now == null and code.cores[i].want);
        try std.testing.expect(stack.cores[i].now == null and stack.cores[i].want);
        try std.testing.expect(source.cores[i].now == null and source.cores[i].want);
        try std.testing.expect(locals.cores[i].now == null and locals.cores[i].want);
    }
}

test "a recovery by another client refreshes memory without a register or board pane" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    bench.shell.recovery.attach(&bench.shell);
    try std.testing.expect(!try bench.answer());
    var memory: gui.shell.memory.Pair = .{};
    memory.cores[0].now = .{};
    bench.shell.memory = &memory;
    const session = bench.rig.session.setup.owner.session();
    try session.setRegister(.cpu0, .r0, 123);
    try session.undoWrite();
    try std.testing.expect(bench.shell.recovery.asked == null);
    try std.testing.expect(memory.cores[0].now != null);
    try bench.rig.answer();
    try bench.shell.pump();
    try std.testing.expect(memory.cores[0].now == null);
    try std.testing.expect(memory.cores[0].want);
    try std.testing.expect(bench.shell.status.pc_id != null);
    const queued = bench.rig.worker.native.count;
    bench.shell.recovery.attach(&bench.shell);
    try std.testing.expectEqual(queued, bench.rig.worker.native.count);
}

test "an external load invalidates a pending acknowledgement from the preceding image" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    bench.shell.recovery.ask(&bench.shell, .undo_write);
    const old = response(&bench, &.{1});
    var bytes: [64]u8 = undefined;
    const loaded = try proto.encode(proto.SessionEvent, .{ .core = .cpu0, .kind = .loaded, .address = 0 }, &bytes);
    try std.testing.expect(!bench.shell.recovery.observe(&bench.shell, .{ .event = .{ .topic = @backingInt(proto.Topic.session), .payload = loaded } }));
    try std.testing.expect(bench.shell.recovery.asked == null);
    try std.testing.expect(!bench.shell.recovery.observe(&bench.shell, old));
    try std.testing.expect(bench.shell.status.pc_id == null);
}
