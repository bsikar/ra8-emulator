const std = @import("std");

const cli = @import("cli_app");
const ra8 = @import("ra8");

const elf_image = ra8.host.jlink.elf_image;
const Stage = cli.probe_stage.Stage;

test "probe_stage reassembles contiguous hex chunks verifies SHA-256 and drops tampered payloads" {
    const gpa = std.testing.allocator;
    const payload = "hello-remote-flash";
    const sha = elf_image.sha256Hex(payload);

    var stage: Stage = .{};
    defer stage.drop();
    try stage.begin(gpa, payload.len, &sha);

    const first_hex = std.fmt.bytesToHex(payload[0..6], .lower);
    const rest_hex = std.fmt.bytesToHex(payload[6..], .upper);
    try stage.chunk(0, &first_hex);
    try std.testing.expectError(error.InvalidElf, stage.chunk(0, &rest_hex));
    try stage.chunk(6, &rest_hex);

    const assembled = try stage.finish();
    defer gpa.free(assembled);
    try std.testing.expectEqualStrings(payload, assembled);

    // Tampered payload fails SHA-256 check and frees buffer cleanly.
    try stage.begin(gpa, 4, &sha);
    try stage.chunk(0, "deadbeef");
    try std.testing.expectError(error.BadChecksum, stage.finish());
    try std.testing.expectEqual(@as(usize, 0), stage.buffer.len);
}
