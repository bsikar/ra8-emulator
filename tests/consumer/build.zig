const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ra8 = b.dependency("ra8_emulator", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "harness_consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "ra8", .module = ra8.module("ra8") }},
        }),
    });
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the external harness consumer").dependOn(&run.step);
}
