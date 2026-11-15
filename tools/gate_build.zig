//! Build wiring for the lightweight formatting, length and terminology gate.
const std = @import("std");

/// The light gate AGENTS.md promises and nothing more: `zig fmt --check` over
/// everything we write, then a file and function length check over the same
/// paths. Anything heavier belongs in ra8-firmware, not in a tool.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const paths = [_][]const u8{ "build.zig", "build_tests.zig", "src", "tests", "tools" };

    var fmt_paths: [paths.len]std.Build.LazyPath = undefined;
    for (paths, &fmt_paths) |path, *lazy| {
        lazy.* = b.path(path);
    }
    const fmt = b.addFmt(.{
        .paths = &fmt_paths,
        .exclude_paths = &.{b.path("tests/consumer/zig-pkg")},
        .check = true,
    });

    const checker = b.addExecutable(.{
        .name = "gate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gate.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run = b.addRunArtifact(checker);
    run.has_side_effects = true;
    for (paths) |path| {
        run.addArg(path);
    }
    run.step.dependOn(&fmt.step);
    run.step.dependOn(terms(b, target));
    return &run.step;
}

/// tools/terms.zig over everything we write.
fn terms(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const paths: []const []const u8 = &.{
        "build.zig",
        "build_tests.zig",
        "build.zig.zon",
        "src",
        "tests",
        "tools",
        "README.md",
        "AGENTS.md",
    };
    const checker = b.addExecutable(.{
        .name = "terms",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/terms.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run = b.addRunArtifact(checker);
    run.has_side_effects = true;
    for (paths) |path| {
        run.addArg(path);
    }
    return &run.step;
}
