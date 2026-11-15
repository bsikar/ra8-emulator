const std = @import("std");
const ra8 = @import("ra8");

const fixture = @import("fixture.zig");
const gpa = std.testing.allocator;
const history = ra8.host.history;

test "failed import removes only its private session and preserves an existing live lease and bytes" {
    var archive = try fixture.recording(true);
    defer archive.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);
    var base = try history.base.Base.openConfigured(gpa, std.testing.io, path, .cache, .{ .recover = false });
    defer base.close();
    var existing = try history.session.Session.create(&base, .{});
    defer _ = existing.close(null, .move) catch @panic("existing test session cleanup failed");
    try existing.dir.writeFile(std.testing.io, .{ .sub_path = "log/events-0", .data = "untouched bytes" });
    var input = std.Io.Reader.fixed(archive.bytes.written());
    try std.testing.expectError(error.TruncatedLog, ra8.rpc.bundle_import.open(gpa, std.testing.io, &input, .{ .history_root = path }));
    const bytes = try existing.dir.readFileAlloc(std.testing.io, "log/events-0", gpa, .limited(32));
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("untouched bytes", bytes);
    var catalog = try history.catalog.Iterator.init(&base);
    try std.testing.expectEqualStrings(&existing.id, (try catalog.next()).?.name);
    try std.testing.expectEqual(null, try catalog.next());
}
