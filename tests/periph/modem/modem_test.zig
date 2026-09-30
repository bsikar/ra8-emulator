//! Covers src/periph/modem.zig: the AT line state machine on SCI7.
const std = @import("std");
const ra8 = @import("ra8");
const modem = ra8.periph.modem;

/// Clock a whole line out, terminator included, and return what came back.
fn line(unit: *modem.Modem, text: []const u8) []const u8 {
    for (text) |byte| {
        const reply = unit.feed(byte);
        if (reply.len != 0) return reply;
    }
    return unit.feed('\r');
}

test "a command is answered only once its line terminates" {
    var unit = modem.Modem{};
    for ("AT+CSQ") |byte| try std.testing.expectEqual(@as(usize, 0), unit.feed(byte).len);
    try std.testing.expectEqualStrings("\r\n+CSQ: 17,99\r\n\r\nOK\r\n", unit.feed('\r'));
    try std.testing.expectEqual(@as(u32, 1), unit.answered);
}

test "a line feed is not a terminator and is not part of the line" {
    var unit = modem.Modem{};
    try std.testing.expectEqual(@as(usize, 0), unit.feed('\n').len);
    try std.testing.expectEqualStrings("\r\nOK\r\n", line(&unit, "A\nT"));
    try std.testing.expectEqual(@as(u32, 1), unit.answered);
}

test "a command the script does not carry is refused, not invented" {
    var unit = modem.Modem{};
    try std.testing.expectEqualStrings("\r\n+CME ERROR: 4\r\n", line(&unit, "AT+NOSUCH"));
    try std.testing.expectEqual(@as(u32, 1), unit.errors);
    try std.testing.expectEqual(@as(u32, 0), unit.answered);
}

test "the demo's whole script is answered in order" {
    var unit = modem.Modem{};
    for ([_][]const u8{ "AT", "ATE0", "AT+CMEE=1", "AT+CPIN?", "AT+CSQ", "AT+CREG=1", "AT+CREG?", "AT+CGATT?" }) |command| {
        try std.testing.expect(line(&unit, command).len != 0);
    }
    try std.testing.expectEqual(@as(u32, 8), unit.answered);
    try std.testing.expectEqual(@as(u32, 0), unit.errors);
}

test "an over-long line is refused rather than answered as its prefix" {
    var unit = modem.Modem{};
    var long: [modem.limits.command + 8]u8 = undefined;
    @memcpy(long[0..2], "AT");
    @memset(long[2..], 'X');
    try std.testing.expectEqualStrings("\r\n+CME ERROR: 4\r\n", line(&unit, &long));
    try std.testing.expectEqual(@as(u32, 1), unit.overlong);
    try std.testing.expectEqual(@as(u32, 0), unit.errors);
}

test "a line that only just fits is still a command" {
    var unit = modem.Modem{};
    var full: [modem.limits.command]u8 = undefined;
    @memcpy(full[0..2], "AT");
    @memset(full[2..], 'X');
    try std.testing.expectEqualStrings("\r\n+CME ERROR: 4\r\n", line(&unit, &full));
    try std.testing.expectEqual(@as(u32, 0), unit.overlong);
    try std.testing.expectEqual(@as(u32, 1), unit.errors);
}

test "the overflow does not carry into the next command" {
    var unit = modem.Modem{};
    var long: [modem.limits.command + 4]u8 = undefined;
    @memset(&long, 'X');
    _ = line(&unit, &long);
    try std.testing.expectEqualStrings("\r\nOK\r\n", line(&unit, "AT"));
    try std.testing.expectEqual(@as(u32, 1), unit.overlong);
    try std.testing.expectEqual(@as(u32, 1), unit.answered);
}

test "a bare terminator is a command the script has nothing for" {
    var unit = modem.Modem{};
    try std.testing.expectEqualStrings("\r\n+CME ERROR: 4\r\n", unit.feed('\r'));
    try std.testing.expectEqual(@as(u32, 1), unit.errors);
}

test "an unterminated line is left pending and the run can say so" {
    var unit = modem.Modem{};
    try std.testing.expect(unit.quiet());
    for ("AT+CSQ") |byte| _ = unit.feed(byte);
    try std.testing.expectEqualStrings("AT+CSQ", unit.pending());
    try std.testing.expect(!unit.quiet());
    _ = unit.feed('\r');
    try std.testing.expectEqual(@as(usize, 0), unit.pending().len);
}

test "the modem on the line is the same modem the counters belong to" {
    var unit = modem.Modem{};
    const on_line = unit.device();
    for ("AT") |byte| _ = on_line.feed(byte);
    try std.testing.expectEqualStrings("\r\nOK\r\n", on_line.feed('\r'));
    try std.testing.expectEqual(@as(u32, 1), unit.answered);
}

test "the modelled line is the MikroBUS UART" {
    try std.testing.expectEqual(@as(usize, 7), modem.line_channel);
}
