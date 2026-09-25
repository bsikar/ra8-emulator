//! Build for the Zig rewrite of the RA8D2 board emulator (#14).
//!
//! The C tree still builds through CMakeLists.txt and stays the shipping
//! emulator until the rewrite reaches parity. This graph builds the Zig
//! binary beside it: pure Zig everywhere except Unicorn and Capstone, which
//! are C libraries and are reached through @cImport, not through a hand-kept
//! C ABI layer of our own.
//!
//! Zig 0.14.1, the version pinned in ra8-firmware .devcontainer/Dockerfile.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Unicorn and Capstone are found the way the CMake build finds them:
    // a prefix the caller names, else the system paths.
    const prefix = b.option([]const u8, "deps-prefix", "Prefix holding include/ and lib/ for unicorn and capstone");

    const exe = b.addExecutable(.{
        .name = "ra8_emulator_zig",
        .root_source_file = b.path("zig/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    link(b, exe, prefix);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Zig emulator").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("zig/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    link(b, tests, prefix);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the Zig unit tests").dependOn(&run_tests.step);
}

fn link(b: *std.Build, c: *std.Build.Step.Compile, prefix: ?[]const u8) void {
    if (prefix) |p| {
        c.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
        c.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{p}) });
    }
    c.linkLibC();
    c.linkSystemLibrary("unicorn");
    c.linkSystemLibrary("capstone");
}
