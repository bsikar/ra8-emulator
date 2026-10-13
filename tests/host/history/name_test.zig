const std = @import("std");
const name = @import("ra8").host.history.name;

test "host lifecycle rejects traversal device names and unsafe components" {
    for ([_][]const u8{ "", ".", "..", "../x", "a/b", "a\\b", "C:foo", "-flag", ".hidden", "end.", "space x", "CON", "nul.bin", "COM1", "lpt9.txt", "a\x00b" }) |text| {
        try std.testing.expectError(error.BadName, name.component(text));
    }
    try std.testing.expectEqualStrings("blob-01.bin", try name.component("blob-01.bin"));
    const too_long: [name.limits.component + 1]u8 = @splat('x');
    try std.testing.expectError(error.BadName, name.component(&too_long));
}

test "host lifecycle distinguishes owned ids drafts trash pointers and foreign entries" {
    const id = try name.id("0123456789abcdef0123456789abcdef");
    var buffer: name.Buffer = undefined;
    try std.testing.expectEqual(name.Kind.session, name.classify(&id).kind);
    try std.testing.expectEqual(name.Kind.creating, name.classify(name.creating(&buffer, &id)).kind);
    try std.testing.expectEqual(name.Kind.trash, name.classify(name.trash(&buffer, &id)).kind);
    try std.testing.expectEqual(name.Kind.pointer, name.classify(name.pointer(&buffer, &id)).kind);
    try std.testing.expectEqual(name.Kind.foreign, name.classify("trash-user-data").kind);
    try std.testing.expectError(error.BadName, name.id("0123456789ABCDEF0123456789ABCDEF"));
}
