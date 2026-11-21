const std = @import("std");

const auth = @import("ra8").host.probe_host.auth;
const wire = @import("ra8").host.probe_host.wire;

test "signed probe-host frames authenticate sequence and payload and reject tampering" {
    var sender: auth.Session = .{ .tx_key = @splat(0x11), .rx_key = @splat(0x22) };
    var receiver: auth.Session = .{ .tx_key = @splat(0x22), .rx_key = @splat(0x11) };
    var bytes: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try wire.send(&writer, &sender, wire.Request{
        .op = .perform,
        .probe_id = "jlink-a",
        .board_id = "fpb-ra8e1",
        .token = 7,
        .action = .uart,
    });
    var reader: std.Io.Reader = .fixed(writer.buffered());
    var scratch: [4096]u8 = undefined;
    const parsed = try wire.receive(wire.Request, std.testing.allocator, &reader, &receiver, &scratch);
    defer parsed.deinit();
    try std.testing.expectEqual(wire.Op.perform, parsed.value.op);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.token);

    const zero_mac = "0000000000000000000000000000000000000000000000000000000000000000";
    var bad_reader: std.Io.Reader = .fixed("2 " ++ zero_mac ++ " {\"op\":\"list\"}\n");
    try std.testing.expectError(
        error.AuthenticationFailed,
        wire.receive(wire.Request, std.testing.allocator, &bad_reader, &receiver, &scratch),
    );
    try std.testing.expectEqual(error.Canceled, wire.mapError("Canceled"));
    try std.testing.expectEqual(error.Timeout, wire.mapError("ProbeTimeout"));
    try std.testing.expectEqual(error.WrongPart, wire.mapError("WrongPart"));
    try std.testing.expectEqual(error.NoPartNumber, wire.mapError("NoPartNumber"));
}
