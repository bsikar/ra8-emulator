//! Covers src/interfaces/cli/window_pace.zig: an engine on its own thread
//! runs one frame per window step and parks between them.
const std = @import("std");
const ra8 = @import("ra8");
const Pacer = ra8.board.window_pace.Pacer;

/// A stand-in engine: stretches of `stretch` instructions until `total`,
/// charging each at its boundary as the run loop's close does.
const Engine = struct {
    pacer: *Pacer,
    stretch: u64,
    total: u64,
    ran: u64 = 0,
    gate: ?*Gate = null,

    fn run(self: *Engine) void {
        defer self.pacer.finish();
        if (!self.pacer.charge(0)) return;
        if (self.gate) |gate| gate.hold();
        while (self.ran < self.total) {
            self.ran += self.stretch;
            if (!self.pacer.charge(self.stretch)) return;
        }
    }
};

/// Lets a test hold the engine after it takes a grant but before it spends it.
const Gate = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    arrived: bool = false,
    released: bool = false,

    fn hold(self: *Gate) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.arrived = true;
        self.changed.broadcast(std.testing.io);
        while (!self.released) self.changed.waitUncancelable(std.testing.io, &self.mutex);
    }

    fn waitArrived(self: *Gate) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        while (!self.arrived) self.changed.waitUncancelable(std.testing.io, &self.mutex);
    }

    fn release(self: *Gate) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.released = true;
        self.changed.broadcast(std.testing.io);
    }
};

test "each step runs whole stretches until the frame's grant is spent" {
    var pacer = Pacer{ .per_frame = 250, .io = std.testing.io };
    var engine = Engine{ .pacer = &pacer, .stretch = 100, .total = 1000 };
    const thread = try std.Thread.spawn(.{}, Engine.run, .{&engine});
    try std.testing.expect(pacer.step());
    try std.testing.expectEqual(@as(u64, 300), engine.ran);
    try std.testing.expect(pacer.step());
    try std.testing.expectEqual(@as(u64, 600), engine.ran);
    try std.testing.expect(pacer.step());
    try std.testing.expectEqual(@as(u64, 900), engine.ran);
    try std.testing.expect(!pacer.step());
    thread.join();
    try std.testing.expectEqual(@as(u64, 1000), engine.ran);
    try std.testing.expect(!pacer.step());
}

test "the engine holds before its first stretch until the window steps" {
    var pacer = Pacer{ .per_frame = 100, .io = std.testing.io };
    var engine = Engine{ .pacer = &pacer, .stretch = 100, .total = 300 };
    const thread = try std.Thread.spawn(.{}, Engine.run, .{&engine});
    while (true) {
        pacer.mutex.lockUncancelable(pacer.io);
        const parked = pacer.parked;
        pacer.mutex.unlock(pacer.io);
        if (parked) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 0), engine.ran);
    try std.testing.expect(pacer.step());
    try std.testing.expectEqual(@as(u64, 100), engine.ran);
    pacer.stop();
    thread.join();
    try std.testing.expectEqual(@as(u64, 100), engine.ran);
}

test "closing the window releases a parked engine and ends the run" {
    var pacer = Pacer{ .per_frame = 50, .io = std.testing.io };
    var engine = Engine{ .pacer = &pacer, .stretch = 50, .total = 1_000_000 };
    const thread = try std.Thread.spawn(.{}, Engine.run, .{&engine});
    try std.testing.expect(pacer.step());
    pacer.stop();
    thread.join();
    try std.testing.expect(engine.ran < engine.total);
    try std.testing.expect(!pacer.step());
}

const Count = struct {
    calls: std.atomic.Value(u32) = .init(0),

    fn hook(self: *Count) ra8.board.window_pace.Hook {
        return .{ .ctx = self, .call = bump };
    }

    fn bump(ctx: *anyopaque) void {
        const self: *Count = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
    }
};

test "the park hook runs on the engine at each park and once at the end" {
    var count = Count{};
    var pacer = Pacer{ .per_frame = 250, .io = std.testing.io, .at_park = count.hook() };
    var engine = Engine{ .pacer = &pacer, .stretch = 100, .total = 1000 };
    const thread = try std.Thread.spawn(.{}, Engine.run, .{&engine});
    waitParked(&pacer);
    try std.testing.expectEqual(@as(u32, 1), count.calls.load(.monotonic));
    try std.testing.expect(pacer.step());
    try std.testing.expectEqual(@as(u32, 2), count.calls.load(.monotonic));
    while (pacer.step()) {}
    thread.join();
    try std.testing.expectEqual(@as(u32, 5), count.calls.load(.monotonic));
}

test "a grant never waits and never runs the engine more than a frame ahead" {
    var pacer = Pacer{ .per_frame = 100, .io = std.testing.io };
    var gate = Gate{};
    var engine = Engine{ .pacer = &pacer, .stretch = 100, .total = 300, .gate = &gate };
    const thread = try std.Thread.spawn(.{}, Engine.run, .{&engine});
    defer thread.join();
    defer pacer.stop();
    waitParked(&pacer);

    const first = pacer.grant();
    gate.waitArrived();
    pacer.mutex.lockUncancelable(pacer.io);
    const before = pacer.left;
    pacer.mutex.unlock(pacer.io);
    const second = pacer.grant();
    pacer.mutex.lockUncancelable(pacer.io);
    const after = pacer.left;
    pacer.mutex.unlock(pacer.io);
    gate.release();

    try std.testing.expect(first);
    try std.testing.expect(second);
    try std.testing.expectEqual(@as(u64, 100), before);
    try std.testing.expectEqual(before, after);
    while (pacer.grant()) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u64, 300), engine.ran);
    try std.testing.expect(!pacer.grant());
}

/// Holds until the engine has reached its first boundary, so the hold
/// before the first stretch is a park and not raced by the first grant.
fn waitParked(pacer: *Pacer) void {
    while (true) {
        pacer.mutex.lockUncancelable(pacer.io);
        const parked = pacer.parked;
        pacer.mutex.unlock(pacer.io);
        if (parked) return;
        std.Thread.yield() catch {};
    }
}
