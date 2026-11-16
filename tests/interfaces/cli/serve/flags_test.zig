//! Managed compiler options compose with independent target and artifact options.
const builtin = @import("builtin");
const std = @import("std");

const cli = @import("cli_app").serve.main;

const cache = if (builtin.os.tag == .windows) "C:/managed cache" else "/managed cache";

test "managed builds require an absolute cache and workspace without replacing target bindings" {
    const valid = &.{
        "emu",       "serve",         "--build-toolchain-cache", cache,    "--workspace", ".",
        "--targets", "bindings.json", "--stdio",                 "fw.elf",
    };
    const parsed = cli.parse(valid).?;
    try std.testing.expectEqualStrings(cache, parsed.build_toolchain_cache.?);
    try std.testing.expectEqualStrings("bindings.json", parsed.targets.?);
    try std.testing.expect(parsed.artifacts_root == null);
    const absent_workspace = &.{ "emu", "serve", "--build-toolchain-cache", cache, "--stdio", "fw.elf" };
    try std.testing.expect(cli.parse(absent_workspace) == null);
    const relative = &.{
        "emu", "serve", "--workspace", ".", "--build-toolchain-cache", "relative", "--stdio", "fw.elf",
    };
    try std.testing.expect(cli.parse(relative) == null);
}

test "managed cache preserves artifact serving and refuses duplicate options" {
    const valid = &.{
        "emu",                     "serve", "--artifacts-root", "spool",  "--workspace", ".",
        "--build-toolchain-cache", cache,   "--stdio",          "fw.elf",
    };
    try std.testing.expectEqualStrings("spool", cli.parse(valid).?.artifacts_root.?);
    const duplicate = &.{
        "emu",                     "serve", "--workspace", ".",      "--build-toolchain-cache", cache,
        "--build-toolchain-cache", cache,   "--stdio",     "fw.elf",
    };
    try std.testing.expect(cli.parse(duplicate) == null);
    try std.testing.expect(cli.parse(&.{ "emu", "serve", "--build-toolchain-cache" }) == null);
}
