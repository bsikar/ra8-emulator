const std = @import("std");
const Owner = @import("cli_app").project.Owner;
const Fixture = @import("../../../host/project/fixture.zig").Fixture;

test "project DAP opener refuses changed inputs before creating a Session target" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.receipt();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "new revision" });
    var owner: Owner = .{ .project = &f.project };
    defer owner.close();
    try std.testing.expectError(error.SourceChanged, Owner.open(&owner, Fixture.receipt_path));
    try std.testing.expect(owner.harness == null);
}
