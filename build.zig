//! The build for the RA8D2 board emulator.
//!
//! One language, one build. The emulator is Zig; Unicorn (the CPU) and
//! Capstone (error-path disassembly) are C libraries and are reached through
//! a single @cImport in src/c.zig. Nothing here is exported back to C and
//! there is no C ABI of our own.
//!
//!   zig build         the emulator into zig-out/bin
//!   zig build run     build and run it
//!   zig build test    the unit tests
//!
//! Point the build at Unicorn and Capstone with -Ddeps-prefix=<prefix> when
//! they are not on the system paths.
//!
//! Zig 0.14.1, the version pinned in ra8-firmware .devcontainer/Dockerfile.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const prefix = b.option([]const u8, "deps-prefix", "Prefix holding include/ and lib/ for unicorn and capstone");

    const exe = b.addExecutable(.{
        .name = "ra8_emulator",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    link(b, exe, prefix);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the emulator").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    link(b, tests, prefix);
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}

fn link(b: *std.Build, c: *std.Build.Step.Compile, prefix: ?[]const u8) void {
    if (prefix) |p| {
        c.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
        c.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{p}) });
        c.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{p}) });
    }
    c.linkLibC();
    c.linkSystemLibrary("unicorn");
    c.linkSystemLibrary("capstone");
}
