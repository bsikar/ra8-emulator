const std = @import("std");

const wire = @import("ra8").host.probe_host.wire;

test "probe-host wire frames round-trip requests replies and error mappings" {
    var bytes: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try wire.send(&writer, wire.Request{
        .op = .perform,
        .probe_id = "jlink-a",
        .board_id = "fpb-ra8e1",
        .token = 7,
        .action = .reset,
    });
    var reader: std.Io.Reader = .fixed(writer.buffered());
    var scratch: [4096]u8 = undefined;
    const parsed = try wire.receive(wire.Request, std.testing.allocator, &reader, &scratch);
    defer parsed.deinit();
    try std.testing.expectEqual(wire.Op.perform, parsed.value.op);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.token);
    try std.testing.expectEqualStrings("fpb-ra8e1", parsed.value.board_id);

    try std.testing.expectEqual(error.TargetBusy, wire.mapError("TargetBusy"));
    try std.testing.expectEqual(error.StaleLease, wire.mapError("StaleLease"));
    try std.testing.expectEqual(error.WrongCore, wire.mapError("WrongCore"));
    try std.testing.expectEqual(error.Unsupported, wire.mapError("Unsupported"));
}
