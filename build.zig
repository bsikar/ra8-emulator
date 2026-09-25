//! The build for the RA8D2 board emulator. Zig only: there is no CMake here.
//!
//! The emulator is being rewritten from C to Zig under #14. Until that reaches
//! parity both trees build from this one graph:
//!
//!   zig build            both binaries
//!   zig build run        the Zig binary
//!   zig build run-c      the C binary, still the shipping emulator
//!   zig build test       the Zig unit tests and the six C test binaries
//!
//! Unicorn and Capstone are C libraries and stay that way. Point the build at
//! them with -Ddeps-prefix=<prefix> when they are not on the system paths.
//!
//! Zig 0.14.1, the version pinned in ra8-firmware .devcontainer/Dockerfile.
const std = @import("std");

/// The C engine, ported file by file into zig/src as the rewrite proceeds.
/// src/periph/board_periph_*.c is discovered, not listed: a new peripheral
/// block is one new file and no edit here, exactly as the CMake glob had it.
const c_engine = [_][]const u8{
    "src/main.c",
    "src/host/emu_host_io.c",
    "src/engine/emu_console.c",
    "src/engine/emu_elf.c",
    "src/engine/emu_elf_reboot.c",
    "src/engine/emu_elf_source.c",
    "src/engine/emu_elf_symbols.c",
    "src/engine/emu_engine.c",
    "src/engine/emu_memmap.c",
    "src/engine/emu_memory_access.c",
    "src/engine/emu_mmio.c",
    "src/engine/emu_mpu.c",
    "src/engine/emu_prof.c",
    "src/engine/emu_presentation.c",
    "src/engine/emu_args.c",
    "src/engine/emu_run.c",
    "src/engine/emu_run_guards.c",
    "src/engine/emu_run_inner.c",
    "src/engine/emu_run_report.c",
    "src/engine/emu_trace.c",
    "src/engine/emu_tz.c",
    "src/engine/emu_view.c",
    "src/engine/emu_view_surface.c",
    "src/engine/emu_view_tile.c",
    "src/engine/emu_usbh_seam.c",
    "src/engine/emu_cpu1.c",
    "src/engine/emu_exc.c",
    "src/engine/emu_exc_scs.c",
    "src/engine/emu_idle.c",
    "src/engine/emu_insn_seams.c",
    "src/engine/emu_seam_div0.c",
    "src/engine/emu_seam_longshift.c",
    "src/engine/emu_seam_sd.c",
    "src/engine/emu_seam_mve.c",
    "src/periph/board_periph.c",
    "src/usb/board_usb.c",
    "src/usb/board_usb_bridge.c",
    "src/usb/board_usb_dev.c",
    "src/usb/board_usb_loop.c",
    "src/usb/board_usb_vhost.c",
    "src/usb/board_usb_host.c",
    "src/io/board_net.c",
    "src/display/board_overlay.c",
    "src/display/board_overlay_draw.c",
    "src/display/board_view_pixels.c",
    "src/io/board_console.c",
    "src/io/board_input.c",
};

/// The source is C23 throughout: 525 typed enums and 403 nullptrs at last
/// count. Zig ships its own clang, so the "your cc is GCC 12" preflight the
/// CMake build needed is gone with it; the pinned toolchain always parses this.
const c_flags = [_][]const u8{
    // gnu23, not c23: CMAKE_C_EXTENSIONS was ON, and the host layer uses the
    // POSIX surface (pread/pwrite, mkstemp, O_CLOEXEC, CLOCK_MONOTONIC) that
    // strict C23 hides.
    "-std=gnu23",
    "-Wall",
    "-Wextra",
    "-Werror",
};

const CTest = struct {
    name: []const u8,
    sources: []const []const u8,
    extra_include: ?[]const u8 = null,
    links_unicorn: bool = false,
};

const c_tests = [_]CTest{
    .{
        .name = "test_emu_host_io",
        .sources = &.{ "tests/src/test_emu_host_io.c", "src/host/emu_host_io.c" },
    },
    .{
        .name = "test_emu_presentation",
        .sources = &.{
            "tests/src/test_emu_presentation.c",
            "src/host/emu_host_io.c",
            "src/engine/emu_presentation.c",
            "src/engine/emu_view_tile.c",
            "src/display/board_overlay.c",
            "src/display/board_overlay_draw.c",
            "src/display/board_view_pixels.c",
        },
        .links_unicorn = true,
    },
    .{
        .name = "test_emu_elf_source",
        .sources = &.{
            "tests/src/test_emu_elf_source.c",
            "src/engine/emu_memory_access.c",
            "src/host/emu_host_io.c",
            "src/engine/emu_elf.c",
            "src/engine/emu_elf_source.c",
            "src/engine/emu_elf_symbols.c",
        },
        .links_unicorn = true,
    },
    .{
        .name = "test_emu_memmap",
        .sources = &.{
            "tests/src/test_emu_memmap.c",
            "src/host/emu_host_io.c",
            "src/engine/emu_memmap.c",
            "src/engine/emu_memory_access.c",
        },
        .links_unicorn = true,
    },
    .{
        .name = "test_emu_mve_vmov",
        .sources = &.{
            "tests/src/test_emu_mve_vmov.c",
            "src/engine/emu_engine.c",
            "src/engine/emu_memory_access.c",
            "src/host/emu_host_io.c",
        },
        .extra_include = "src/engine",
        .links_unicorn = true,
    },
    .{
        .name = "test_board_sd_storage",
        .sources = &.{
            "tests/src/test_board_sd_storage.c",
            "src/host/emu_host_io.c",
            "src/periph/board_periph_sd_image.c",
            "src/periph/board_periph_sd_format.c",
        },
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const prefix = b.option([]const u8, "deps-prefix", "Prefix holding include/ and lib/ for unicorn and capstone");

    const test_step = b.step("test", "Run the Zig unit tests and the C test binaries");

    // The Zig rewrite (#14).
    const exe = b.addExecutable(.{
        .name = "ra8_emulator_zig",
        .root_source_file = b.path("zig/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkDeps(b, exe, prefix, true);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Zig emulator").dependOn(&run.step);

    const zig_tests = b.addTest(.{
        .root_source_file = b.path("zig/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkDeps(b, zig_tests, prefix, true);
    test_step.dependOn(&b.addRunArtifact(zig_tests).step);

    // The C emulator, still the one that ships.
    const c_exe = b.addExecutable(.{
        .name = "ra8_emulator",
        .target = target,
        .optimize = optimize,
    });
    c_exe.addCSourceFiles(.{ .files = &c_engine, .flags = &c_flags });
    c_exe.addCSourceFiles(.{ .files = peripheralBlocks(b), .flags = &c_flags });
    addBoardView(b, c_exe, target);
    c_exe.addIncludePath(b.path("inc"));
    linkDeps(b, c_exe, prefix, true);
    b.installArtifact(c_exe);

    const run_c = b.addRunArtifact(c_exe);
    run_c.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_c.addArgs(args);
    b.step("run-c", "Run the C emulator").dependOn(&run_c.step);

    for (c_tests) |spec| {
        const t = b.addExecutable(.{
            .name = spec.name,
            .target = target,
            .optimize = optimize,
        });
        t.addCSourceFiles(.{ .files = spec.sources, .flags = &c_flags });
        t.addIncludePath(b.path("inc"));
        if (spec.extra_include) |dir| t.addIncludePath(b.path(dir));
        linkDeps(b, t, prefix, spec.links_unicorn);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

fn linkDeps(b: *std.Build, c: *std.Build.Step.Compile, prefix: ?[]const u8, libraries: bool) void {
    if (prefix) |p| {
        c.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
        c.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{p}) });
        c.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{p}) });
    }
    c.linkLibC();
    if (!libraries) return;
    c.linkSystemLibrary("unicorn");
    c.linkSystemLibrary("capstone");
}

/// board_view is the live board window: the Cocoa backend on macOS, the
/// headless shim everywhere else. Exactly one is compiled, so a Linux build
/// links no AppKit symbols and --view falls back to headless.
fn addBoardView(b: *std.Build, c: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .macos) {
        c.addCSourceFiles(.{
            .files = &.{"src/display/board_view.m"},
            .flags = &(c_flags ++ [_][]const u8{"-fobjc-arc"}),
        });
        c.addCSourceFiles(.{ .files = &.{"src/display/board_view_provider.c"}, .flags = &c_flags });
        c.linkFramework("Cocoa");
        c.linkFramework("QuartzCore");
        c.linkFramework("CoreGraphics");
    } else {
        c.addCSourceFiles(.{ .files = &.{"src/display/board_view_stub.c"}, .flags = &c_flags });
    }
    _ = b;
}

/// Every src/periph/board_periph_*.c, discovered at configure time. Each block
/// self-registers with the core through a constructor, so the core keeps no
/// central list and blocks can be added in parallel with no edit to this file.
fn peripheralBlocks(b: *std.Build) []const []const u8 {
    var found = std.ArrayList([]const u8).init(b.allocator);
    var dir = std.fs.cwd().openDir(b.pathFromRoot("src/periph"), .{ .iterate = true }) catch
        @panic("src/periph is missing: the peripheral blocks cannot be found");
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch @panic("cannot read src/periph")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "board_periph_")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
        found.append(b.fmt("src/periph/{s}", .{entry.name})) catch @panic("OOM");
    }
    const files = found.toOwnedSlice() catch @panic("OOM");
    std.mem.sort([]const u8, files, {}, lessThan);
    return files;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
