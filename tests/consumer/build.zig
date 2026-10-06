const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ra8 = b.dependency("ra8_emulator", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "harness_consumer",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("ra8", ra8.module("ra8"));
    exe.linkLibC();
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the external harness consumer").dependOn(&run.step);
}
