//! Covers src/periph/riic_rx.zig: the dummy read that starts the clock, the
//! bytes served after it, and the reads past the end of what was staged.
const std = @import("std");
const ra8 = @import("ra8");
const rx = ra8.periph.riic_rx;
const flag = ra8.periph.riic_flags;

test "a fresh path holds nothing and is quiet" {
    var path = rx.Rx{};
    try std.testing.expect(!path.holding());
    try std.testing.expect(path.quiet());
}

test "the first access is the dummy read that starts the clock" {
    var path = rx.Rx{};
    path.staged[0] = 0xA5;
    path.stage(1);

    var status: u8 = flag.icsr2.rdrf;
    try std.testing.expectEqual(@as(?u8, null), path.take(&status));
    try std.testing.expect(path.holding());
    try std.testing.expectEqual(@as(?u8, 0xA5), path.take(&status));
}

test "RDRF stands while a byte is waiting and goes away with the last" {
    var path = rx.Rx{};
    path.staged[0] = 1;
    path.staged[1] = 2;
    path.stage(2);

    var status: u8 = 0;
    _ = path.take(&status);
    _ = path.take(&status);
    try std.testing.expectEqual(flag.icsr2.rdrf, status & flag.icsr2.rdrf);
    _ = path.take(&status);
    try std.testing.expectEqual(@as(u8, 0), status & flag.icsr2.rdrf);
    try std.testing.expect(!path.holding());
}

test "a read past the end answers nothing and is counted" {
    var path = rx.Rx{};
    path.staged[0] = 7;
    path.stage(1);

    var status: u8 = 0;
    _ = path.take(&status);
    _ = path.take(&status);
    try std.testing.expectEqual(@as(?u8, null), path.take(&status));
    try std.testing.expectEqual(@as(u32, 1), path.overread);
    try std.testing.expect(!path.quiet());
}

test "opening a frame empties the path and arms the dummy read again" {
    var path = rx.Rx{};
    path.staged[0] = 9;
    path.stage(1);
    var status: u8 = 0;
    _ = path.take(&status);
    _ = path.take(&status);

    path.open();
    try std.testing.expect(!path.holding());
    try std.testing.expectEqual(@as(?u8, null), path.take(&status));
}

test "an empty answer holds nothing at all" {
    var path = rx.Rx{};
    path.stage(0);
    try std.testing.expect(!path.holding());
}
