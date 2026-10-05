const std = @import("std");
const ra8 = @import("ra8");

test "versioned profiles parse sensor and companion endpoints" {
    const profile = try ra8.board.profile.parse(
        "version=1\nsensor=max17048@i2c:riic@0x37\ncompanion=c6@uart:sci2\n",
    );
    try std.testing.expectEqual(@as(usize, 2), profile.count);
    try std.testing.expectEqualStrings("max17048", profile.fits[0].name);
    try std.testing.expectEqualStrings("c6", profile.fits[1].name);
    try std.testing.expect(profile.fits[1].at == .uart);
    try std.testing.expectEqual(@as(u4, 2), profile.fits[1].at.uart.channel);
}

test "profiles reject unsupported versions and malformed fitted models" {
    try std.testing.expectError(error.BadVersion, ra8.board.profile.parse("version=2\n"));
    try std.testing.expectError(error.UnknownModel, ra8.board.profile.parse("version=1\nsensor=missing@uart:sci1\n"));
}
