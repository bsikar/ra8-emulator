const std = @import("std");
const dirs = @import("ra8").host.app_dirs;
const allocator = std.testing.allocator;

test "host lifecycle XDG paths separate cache kept and runtime with safe override namespaces" {
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/fixture");
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");
    const cache = try dirs.historyCache(allocator, &env, .xdg);
    defer allocator.free(cache);
    const kept = try dirs.historyKept(allocator, &env, .xdg);
    defer allocator.free(kept);
    const runtime = try dirs.runtime(allocator, &env, .xdg);
    defer allocator.free(runtime);
    try std.testing.expectEqualStrings("/home/fixture/.cache/ra8_emulator/history", cache);
    try std.testing.expectEqualStrings("/home/fixture/.local/share/ra8_emulator/kept_history", kept);
    try std.testing.expectEqualStrings("/run/user/1000/ra8_emulator", runtime);
    try env.put("RA8_HISTORY_DIR", "/owned/");
    const override = try dirs.historyCache(allocator, &env, .xdg);
    defer allocator.free(override);
    try std.testing.expectEqualStrings("/owned/ra8_history", override);
    try env.put("RA8_HISTORY_DIR", "relative");
    try std.testing.expectError(error.RelativePath, dirs.historyCache(allocator, &env, .xdg));
}

test "host lifecycle Windows paths use nonroaming local data and macOS separates data" {
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("LOCALAPPDATA", "C:\\Users\\fixture\\AppData\\Local");
    try env.put("APPDATA", "C:\\Users\\fixture\\AppData\\Roaming");
    const cache = try dirs.historyCache(allocator, &env, .windows);
    defer allocator.free(cache);
    const kept = try dirs.historyKept(allocator, &env, .windows);
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("C:\\Users\\fixture\\AppData\\Local\\ra8_emulator\\history", cache);
    try std.testing.expectEqualStrings("C:\\Users\\fixture\\AppData\\Local\\ra8_emulator\\kept_history", kept);
    try env.put("HOME", "/Users/fixture");
    const mac_cache = try dirs.historyCache(allocator, &env, .macos);
    defer allocator.free(mac_cache);
    const mac_kept = try dirs.historyKept(allocator, &env, .macos);
    defer allocator.free(mac_kept);
    try std.testing.expectEqualStrings("/Users/fixture/Library/Caches/ra8_emulator/history", mac_cache);
    try std.testing.expectEqualStrings("/Users/fixture/Library/Application Support/ra8_emulator/kept_history", mac_kept);
}
