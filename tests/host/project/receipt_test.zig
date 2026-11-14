const std = @import("std");
const api = @import("ra8").host.project;
const Fixture = @import("fixture.zig").Fixture;

test "project receipt cannot substitute a guessed build id for its paired original record" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.receipt();
    const bytes = try api.files.read(std.testing.allocator, std.testing.io, f.tmp.dir, Fixture.receipt_path, 32_768);
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(api.receipt.Receipt, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    parsed.value.build_id += 1;
    const changed = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(changed);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = Fixture.receipt_path, .data = changed });
    try std.testing.expectError(error.InvalidBuildReceipt, f.project.load(Fixture.receipt_path));
}
