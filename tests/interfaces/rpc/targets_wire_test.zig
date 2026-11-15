const std = @import("std");
const proto = @import("ra8").rpc.session.rpc;
const wire = @import("ra8").rpc.targets_wire;

test "target wire preserves the full selection and rejects oversized identity fields" {
    const selected: wire.Selection = .{
        .host_id = "host",
        .probe_id = "probe",
        .board_id = "board",
        .generation = 0xffff_ffff_ffff_fffe,
        .disambiguation = "physical-binding",
    };
    var storage: [1024]u8 = undefined;
    const bytes = try proto.encode(wire.Perform, wire.operation(selected, .step), &storage);
    const found = try proto.decode(wire.Perform, bytes);
    try std.testing.expectEqual(selected.generation, found.generation);
    try std.testing.expectEqualStrings(selected.host_id, found.host_id);
    try std.testing.expectEqualStrings(selected.probe_id, found.probe_id);
    try std.testing.expectEqualStrings(selected.board_id, found.board_id);
    try std.testing.expectEqualStrings(selected.disambiguation, found.disambiguation);
    try std.testing.expectEqual(.step, found.action);
    var invalid = selected;
    const long: [129]u8 = @splat('b');
    invalid.board_id = &long;
    try std.testing.expectError(error.Oversize, proto.encode(wire.Selection, invalid, &storage));
}
