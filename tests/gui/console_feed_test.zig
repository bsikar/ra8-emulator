//! Covers src/gui/console_feed.zig: sent bytes reach each channel's log
//! stamped with board time, only after a publish, and an outbox past its
//! limit counts what it could not keep.
const std = @import("std");
const ra8 = @import("ra8");
const console_feed = ra8.gui.console_feed;
const console_log = ra8.gui.console_log;

const Clock = struct {
    ns: u64 = 0,

    fn now(self: *Clock) console_feed.Now {
        return .{ .ctx = self, .now = read };
    }

    fn read(ctx: *anyopaque) u64 {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        return self.ns;
    }
};

fn send(tap: anytype, channel: usize, text: []const u8) void {
    for (text) |byte| tap.sent(tap.ctx, channel, byte);
}

test "bytes land in their channel's log with the time they were sent" {
    var clock = Clock{};
    var feed = console_feed.Feed{ .allocator = std.testing.allocator, .now = clock.now() };
    defer feed.deinit();
    var logs = [_]console_log.Log{ console_log.Log.init(std.testing.allocator, 4), console_log.Log.init(std.testing.allocator, 4) };
    defer for (&logs) |*log| log.deinit();
    const tap = feed.tap();
    clock.ns = 100;
    send(tap, 1, "up");
    clock.ns = 250;
    send(tap, 1, "\n");
    send(tap, 0, "a\n");
    send(tap, 7, "far\n");
    try std.testing.expectEqual(@as(u64, 0), try feed.drain(&logs));
    try std.testing.expectEqual(@as(usize, 0), logs[1].lines().len);
    feed.publish();
    try std.testing.expectEqual(@as(u64, 0), try feed.drain(&logs));
    try std.testing.expectEqualStrings("up", logs[1].lines()[0].text);
    try std.testing.expectEqual(@as(u64, 250), logs[1].lines()[0].at_ns);
    try std.testing.expectEqualStrings("a", logs[0].lines()[0].text);
    try std.testing.expectEqual(@as(usize, 0), try feed.drain(&logs) - 0);
}

test "an outbox past its limit keeps what fits and counts the rest" {
    var clock = Clock{};
    var feed = console_feed.Feed{ .allocator = std.testing.allocator, .now = clock.now(), .limit = 3 };
    defer feed.deinit();
    var logs = [_]console_log.Log{console_log.Log.init(std.testing.allocator, 4)};
    defer logs[0].deinit();
    send(feed.tap(), 0, "abcde");
    feed.publish();
    send(feed.tap(), 0, "f");
    feed.publish();
    try std.testing.expectEqual(@as(u64, 3), try feed.drain(&logs));
    try std.testing.expectEqualStrings("abc", logs[0].partial());
    send(feed.tap(), 0, "g\n");
    feed.publish();
    try std.testing.expectEqual(@as(u64, 3), try feed.drain(&logs));
    try std.testing.expectEqualStrings("abcg", logs[0].lines()[0].text);
}
