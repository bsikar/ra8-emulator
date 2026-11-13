const std = @import("std");
const entry = @import("ra8").host.workspace.entry;

test "workspace versions distinguish missing files and identity changes" {
    const missing: entry.Version = .{};
    try std.testing.expect(missing.same(.{}));
    try std.testing.expect(!missing.same(.{ .kind = .file }));
    const before: entry.Version = .{ .kind = .file, .size = 4, .modified_ns = 5, .identity = 6 };
    try std.testing.expect(!before.same(.{ .kind = .file, .size = 4, .modified_ns = 5, .identity = 7 }));
    try std.testing.expectEqual(entry.Kind.symlink, entry.kind(.sym_link));
}
