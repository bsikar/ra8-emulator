//! The calendar behind the RTC: BCD both ways, the carry chain, and what an
//! armed alarm field agrees with.
const std = @import("std");
const ra8 = @import("ra8");

const clock = ra8.periph.rtc_clock;

test "bcd packs and unpacks a two-digit value" {
    try std.testing.expectEqual(@as(u8, 0x00), clock.bcd.fromBinary(0));
    try std.testing.expectEqual(@as(u8, 0x09), clock.bcd.fromBinary(9));
    try std.testing.expectEqual(@as(u8, 0x10), clock.bcd.fromBinary(10));
    try std.testing.expectEqual(@as(u8, 0x59), clock.bcd.fromBinary(59));
    try std.testing.expectEqual(@as(u8, 0), clock.bcd.toBinary(0x00));
    try std.testing.expectEqual(@as(u8, 23), clock.bcd.toBinary(0x23));
    try std.testing.expectEqual(@as(u8, 99), clock.bcd.toBinary(0x99));
}

test "a year past the century wraps, because the counter holds two digits" {
    try std.testing.expectEqual(@as(u8, 0x00), clock.bcd.fromBinary(100));
    try std.testing.expectEqual(@as(u8, 0x01), clock.bcd.fromBinary(101));
}

test "a second carries into the minute and the minute into the hour" {
    var now = clock.Calendar{ .second = 59, .minute = 59, .hour = 7 };
    now.advance();
    try std.testing.expectEqual(@as(u8, 0), now.second);
    try std.testing.expectEqual(@as(u8, 0), now.minute);
    try std.testing.expectEqual(@as(u8, 8), now.hour);
}

test "midnight rolls the day, and the model's 28-day month rolls the month" {
    var now = clock.Calendar{ .second = 59, .minute = 59, .hour = 23, .day = 27 };
    now.advance();
    try std.testing.expectEqual(@as(u8, 0), now.hour);
    try std.testing.expectEqual(@as(u8, 28), now.day);

    now = clock.Calendar{ .second = 59, .minute = 59, .hour = 23, .day = 28, .month = 3 };
    now.advance();
    try std.testing.expectEqual(@as(u8, 1), now.day);
    try std.testing.expectEqual(@as(u8, 4), now.month);
}

test "the last second of the year carries into the next one" {
    var now = clock.Calendar{
        .second = 59,
        .minute = 59,
        .hour = 23,
        .day = 28,
        .month = 12,
        .year = 25,
    };
    now.advance();
    try std.testing.expectEqual(@as(u8, 1), now.day);
    try std.testing.expectEqual(@as(u8, 1), now.month);
    try std.testing.expectEqual(@as(u8, 26), now.year);
}

test "reset leaves a date that exists, not the zeroth of the zeroth" {
    const now = clock.Calendar{};
    try std.testing.expectEqual(@as(u8, 1), now.day);
    try std.testing.expectEqual(@as(u8, 1), now.month);
}

test "an unarmed alarm field agrees with anything, an armed one only with its value" {
    try std.testing.expect(clock.alarm.agrees(0x00, 17));
    try std.testing.expect(clock.alarm.agrees(0x30, 17));
    try std.testing.expect(clock.alarm.agrees(0x80 | 0x17, 17));
    try std.testing.expect(!clock.alarm.agrees(0x80 | 0x17, 18));
    try std.testing.expect(clock.alarm.armed(0x80));
    try std.testing.expect(!clock.alarm.armed(0x7F));
}
