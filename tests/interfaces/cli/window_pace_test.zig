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

    fn run(self: *Engine) void {
        defer self.pacer.finish();
        if (!self.pacer.charge(0)) return;
        while (self.ran < self.total) {
            self.ran += self.stretch;
            if (!self.pacer.charge(self.stretch)) return;
        }
    }
};

test "each step runs whole stretches until the frame's grant is spent" {
    var pacer = Pacer{ .per_frame = 250 };
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
    var pacer = Pacer{ .per_frame = 100 };
    var engine = Engine{ .pacer = &pacer, .stretch = 100, .total = 300 };
    const thread = try std.Thread.spawn(.{}, Engine.run, .{&engine});
    while (true) {
        pacer.mutex.lock();
        const parked = pacer.parked;
        pacer.mutex.unlock();
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
    var pacer = Pacer{ .per_frame = 50 };
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
    var pacer = Pacer{ .per_frame = 250, .at_park = count.hook() };
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
    var pacer = Pacer{ .per_frame = 100 };
    var engine = Engine{ .pacer = &pacer, .stretch = 100, .total = 300 };
    const thread = try std.Thread.spawn(.{}, Engine.run, .{&engine});
    waitParked(&pacer);
    try std.testing.expect(pacer.grant());
    // Before the engine has taken the grant, another one is no top-up.
    pacer.mutex.lock();
    const left = pacer.left;
    pacer.mutex.unlock();
    try std.testing.expect(pacer.grant());
    pacer.mutex.lock();
    try std.testing.expect(pacer.left <= left);
    pacer.mutex.unlock();
    while (pacer.grant()) std.Thread.yield() catch {};
    thread.join();
    try std.testing.expectEqual(@as(u64, 300), engine.ran);
    try std.testing.expect(!pacer.grant());
}

/// Holds until the engine has reached its first boundary, so the hold
/// before the first stretch is a park and not raced by the first grant.
fn waitParked(pacer: *Pacer) void {
    while (true) {
        pacer.mutex.lock();
        const parked = pacer.parked;
        pacer.mutex.unlock();
        if (parked) return;
        std.Thread.yield() catch {};
    }
}
