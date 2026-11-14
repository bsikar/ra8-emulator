const std = @import("std");
const config = @import("ra8").host.project.config;

test "project configuration rejects incompatible versions, escaping roots and invalid explicit compilers" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedProjectVersion, config.parse(a, "{\"version\":2,\"target\":\"ra8d2\",\"recipes\":[]}"));
    try std.testing.expectError(error.InvalidPath, config.parse(a, "{\"version\":1,\"root\":\"../outside\",\"target\":\"ra8d2\",\"recipes\":[]}"));
    try std.testing.expectError(error.InvalidCompiler, config.parse(a, "{\"version\":1,\"compiler\":\"zig\",\"target\":\"ra8d2\",\"recipes\":[]}"));
    try std.testing.expectError(error.DuplicateProjectRecipe, config.parse(a, "{\"version\":1,\"target\":\"ra8d2\",\"recipes\":[{\"name\":\"debug\",\"artifact\":\"bin/fw.elf\"},{\"name\":\"debug\",\"artifact\":\"other.elf\"}]}"));
    const parsed = try config.parse(a, "{\"version\":1,\"target\":\"ra8d2\",\"recipes\":[{\"name\":\"debug\",\"artifact\":\"bin/fw.elf\"}],\"source_mappings\":[{\"client\":\"C:/phone/project\"}]}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bin/fw.elf", (try config.findRecipe(parsed.value, "debug")).artifact);
    try std.testing.expectError(error.UnknownProjectRecipe, config.findRecipe(parsed.value, "old"));
}
