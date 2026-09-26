//! The build for the RA8D2 board emulator.
//!
//! One language, one build. The emulator is Zig; Unicorn (the CPU) and
//! Capstone (error-path disassembly) are C libraries and are reached through
//! a single @cImport in src/core/c.zig. Nothing here is exported back to C and
//! there is no C ABI of our own.
//!
//!   zig build         the emulator into zig-out/bin
//!   zig build run     build and run it
//!   zig build test    the unit tests under tests/
//!   zig build gate    zig fmt --check, then the file and function length
//!                     checks in tools/gate.zig
//!
//! Source is grouped, not flat: src/core/ is the machine (engine, elf,
//! memmap, disasm and the one C boundary), src/periph/ is everything that
//! answers on the peripheral bus, and src/main.zig sits on top. Tests live
//! in tests/ on mirrored paths, never in a `test` block at the bottom of a
//! source file, and tests/all.zig is the root that pulls them in.
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

    // One library module, reached as "ra8" by the executable and by the
    // tests, so neither has to walk relative paths into src/.
    const emu = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (prefix) |p| emu.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });

    const exe = b.addExecutable(.{
        .name = "ra8_emulator",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("ra8", emu);
    link(b, exe, prefix);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the emulator").dependOn(&run.step);

    // The gate is a program of its own: build.zig owns the formatter check,
    // tools/gate.zig owns the length checks, and the tests cover its scanner
    // through the same module the gate executable is built from.
    const gate_mod = b.createModule(.{
        .root_source_file = b.path("tools/gate.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("ra8", emu);
    tests.root_module.addImport("gate", gate_mod);
    link(b, tests, prefix);
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);

    b.step("gate", "Check formatting and file and function length").dependOn(gate(b, target));
}

/// The light gate AGENTS.md promises and nothing more: `zig fmt --check` over
/// everything we write, then a file and function length check over the same
/// paths. Anything heavier belongs in ra8-firmware, not in a tool.
fn gate(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const paths: []const []const u8 = &.{ "build.zig", "src", "tests", "tools" };

    const fmt = b.addFmt(.{ .paths = paths, .check = true });

    const checker = b.addExecutable(.{
        .name = "gate",
        .root_source_file = b.path("tools/gate.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const run = b.addRunArtifact(checker);
    run.has_side_effects = true;
    for (paths) |path| run.addArg(path);
    run.step.dependOn(&fmt.step);
    return &run.step;
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
