const std = @import("std");
const plan = @import("ra8").host.toolchain.plan;

test "toolchain compiler override precedence refuses an invalid winner rather than falling back" {
    const allocator = std.testing.allocator;
    const selected = try plan.make(allocator, .{ .host = "x86_64-linux", .target = "ra8d2", .project_zig = "/project tool/zig", .backend_zig = "/backend/zig" });
    try std.testing.expectEqualStrings("/project tool/zig", selected.compiler_path);
    try std.testing.expectEqual(.project_override, selected.compiler_source);
    try std.testing.expectError(error.InvalidToolPath, plan.make(allocator, .{ .host = "x86_64-linux", .target = "ra8d2", .project_zig = "zig", .backend_zig = "/backend/zig" }));
    const backend = try plan.make(allocator, .{ .host = "x86_64-windows", .target = "ra8d2", .backend_zig = "C:/tools/zig.exe" });
    try std.testing.expectEqual(.backend_override, backend.compiler_source);
    try std.testing.expect(backend.ra_sdk_reference != null);
    try std.testing.expectError(error.InvalidToolPath, plan.make(allocator, .{ .host = "x86_64-windows", .target = "ra8d2", .backend_zig = "\\tools\\zig.exe" }));
    try std.testing.expectError(error.InvalidToolPath, plan.make(allocator, .{ .host = "x86_64-linux", .target = "ra8d2", .backend_zig = "C:/tools/zig.exe" }));
}

test "offline toolchain plans require verified dependencies and never claim an unprobed cache is ready" {
    const result = try plan.make(std.testing.allocator, .{ .host = "x86_64-linux", .target = "ra8p1", .cache_root = "/private/cache", .offline = true });
    defer std.testing.allocator.free(result.compiler_path);
    try std.testing.expectEqual(.managed_required, result.compiler_source);
    try std.testing.expectEqual(@as(u32, 1), result.manifest_version);
    try std.testing.expect(result.offline);
    try std.testing.expect(std.mem.indexOf(u8, result.compiler_path, result.pinned_baseline.sha256) != null);
    try std.testing.expect(std.mem.endsWith(u8, result.compiler_path, "/zig-x86_64-linux-0.17.0/zig"));
    try std.testing.expect(std.mem.startsWith(u8, result.availability, "not probed"));
    try std.testing.expect(std.mem.startsWith(u8, result.flash_gate, "blocked"));
    const grove = try plan.make(std.testing.allocator, .{ .host = "x86_64-linux", .target = "grove-vision-ai-v2" });
    try std.testing.expect(grove.ra_sdk_reference == null);
}
