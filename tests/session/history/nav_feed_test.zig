//! Covers src/session/history/nav_feed.zig: each iteration, thread switch
//! and exception entry or return is indexed once, whatever order the run
//! reaches it in, and two events at the same slot are both kept.
const std = @import("std");
const ra8 = @import("ra8");
const feed_mod = ra8.session.history_nav_feed;
const nav_mod = ra8.session.history_nav_index;
const Event = ra8.session.rtos.trace.Event;

const Rig = struct {
    grid: ra8.chip.core.scheduler.State = .{ .at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired } },
    slots: u64 = 0,
    session: ra8.session.api.Session = undefined,
    nav: nav_mod.NavIndex = undefined,
    feed: feed_mod.NavFeed = undefined,

    fn init(self: *Rig) void {
        self.session = .{
            .live = .{ .core = undefined, .machine = undefined, .index = 0, .boundary = null, .budget = 1000 },
            .grid = &self.grid,
        };
        self.nav = nav_mod.NavIndex.init(std.testing.allocator);
        self.feed = .{ .nav = &self.nav, .session = &self.session, .saved = &self.grid, .slots = &self.slots };
    }

    fn deinit(self: *Rig) void {
        self.feed.deinit();
        self.nav.deinit();
    }

    /// Stands the run at round `r`, `o` slots into it.
    fn at(self: *Rig, r: u64, o: u64) void {
        self.grid.at.r = r;
        self.slots = o;
    }

    fn send(self: *Rig, event: Event) void {
        const observer = self.feed.observer();
        observer.eventFn(observer.context, event);
    }

    fn round(self: *Rig, r: u64) void {
        feed_mod.NavFeed.onRound(&self.feed, .{ .branch = 0, .r = r, .phase = .cpu0, .o = 0, .gap = .retired });
    }
};

test "events a restore skipped are indexed when a replay passes them later" {
    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    rig.at(10, 100);
    rig.send(.{ .when = 0, .core = 0, .kind = .enter, .exception = 15 });
    // A seek back replays an earlier stretch the restore jumped over.
    rig.at(2, 20);
    rig.send(.{ .when = 0, .core = 0, .kind = .enter, .exception = 15 });
    try std.testing.expectEqual(@as(usize, 2), rig.nav.isrTransitionCount());
    // Passing the same event again adds nothing.
    rig.send(.{ .when = 0, .core = 0, .kind = .enter, .exception = 15 });
    try std.testing.expectEqual(@as(usize, 2), rig.nav.isrTransitionCount());
}

test "a tail-chained return and entry at one slot are both indexed" {
    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    rig.at(4, 40);
    rig.send(.{ .when = 0, .core = 0, .kind = .leave, .exception = 15 });
    rig.send(.{ .when = 0, .core = 0, .kind = .enter, .exception = 16 });
    try std.testing.expectEqual(@as(usize, 2), rig.nav.isrTransitionCount());
    rig.send(.{ .when = 0, .core = 0, .kind = .idle });
    rig.send(.{ .when = 0, .core = 0, .kind = .switch_to, .thread = 0x2000_0100 });
    try std.testing.expectEqual(@as(usize, 2), rig.nav.rtosSwitchCount());
}

test "iterations reached out of order are kept in position order once each" {
    var rig: Rig = .{};
    rig.init();
    defer rig.deinit();

    rig.at(10, 1000);
    rig.round(10);
    // A seek back replays rounds a restore skipped; CPU0's counter is back
    // at what it was there.
    rig.at(5, 500);
    rig.round(5);
    rig.at(10, 1000);
    rig.round(10);
    rig.at(7, 700);
    rig.round(7);
    try std.testing.expectEqual(@as(usize, 3), rig.nav.iterations.items.len);
    try std.testing.expectEqual(@as(u64, 5), rig.nav.getIteration(1).?.r);
    try std.testing.expectEqual(@as(u64, 7), rig.nav.getIteration(2).?.r);
    try std.testing.expectEqual(@as(u64, 10), rig.nav.getIteration(3).?.r);
    for (rig.nav.iterations.items, 1..) |entry, n| try std.testing.expectEqual(@as(u64, n), entry.n);
    try std.testing.expectEqual(@as(u64, 500), rig.nav.getIterationSlots(1).?);
    try std.testing.expectEqual(@as(u64, 700), rig.nav.getIterationSlots(2).?);
    try std.testing.expectEqual(@as(u64, 1000), rig.nav.getIterationSlots(3).?);
}
