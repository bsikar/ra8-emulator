//! The build for the RA8D2 board emulator.
//!
//! The emulator, CPU and disassembler use Zig. Only libc links to C;
//! nothing is exported back to C and there is no C ABI of our own.
//!
//!    zig build          the emulator into zig-out/bin
//!    zig build run      build and run it
//!    zig build test     the unit tests under tests/
//!    zig build gate     zig fmt --check, then the file and function length
//!                       checks in tools/gate.zig
//!
//! The Zig source is ten libraries and one application, each a build module
//! rooted at root.zig in its own directory (ADR 0004, AGENTS.md):
//!
//!    src/host/                ra8_host        the host OS: sockets, files, cameras
//!    src/snapshot/            ra8_snapshot    the snapshot format
//!    src/chip/                ra8_chip        the cores (core/) and the on-chip
//!                                             blocks (periph/)
//!    src/components/          ra8_components  off-chip parts and the plug layer
//!    src/board/               ra8_board       the board, its image loader and run policy
//!    src/session/             ra8_session     the embedding API and the debugger
//!    src/interfaces/render/   ra8_render      drawing and the image encoders
//!    src/interfaces/rpc/      ra8_rpc          the session over a wire
//!    src/interfaces/gdb/      ra8_gdb          the GDB remote server
//!    src/interfaces/usbip/    ra8_usbip        the USB/IP bridge
//!    src/interfaces/cli/      cli_app          ra8_emulator
//!    src/interfaces/gui/                       TypeScript web client
//!
//! src/root.zig re-exports libraries. Tests mirror source under tests/;
//! tests/all.zig and tests/all_host.zig collect them, with no inline tests.
//!
//! Zig 0.17.0, the version pinned in ra8-firmware .devcontainer/Dockerfile.
const debug_build = @import("tools/debug_build.zig");
const modules_build = @import("tools/modules_build.zig");

const std = @import("std");

const build_tests = @import("build_tests.zig");
const gate_build = @import("tools/gate_build.zig");
const lint_build = @import("tools/lint/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const peer_only = b.option(
        bool,
        "host-move-peer-only",
        "Build the internal native directory move peer",
    ) orelse false;

    const firmware = b.dependency("ra8_firmware", .{});
    const libs = modules_build.libraries(b, target, optimize, firmware);
    // Tests and embedders reach the libraries through the "ra8" umbrella.
    const emu = b.addModule("ra8", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    libs.importInto(emu);
    const cli = modules_build.application(b, target, optimize, libs, firmware);

    const exe = executable(b, target, optimize, cli, libs, peer_only);
    const peers = testPeers(b, target, optimize, cli);
    const move_peer = if (peer_only) exe else peers[0];
    const lifecycle_peer = peers[1];

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the emulator").dependOn(&run.step);

    debug_build.add(b);
    usbipAttach(b, target, optimize);
    lint_build.add(b, @This());

    configureTests(b, target, optimize, emu, cli, exe, move_peer, lifecycle_peer);

    b.step(
        "gate",
        "Check formatting, file and function length, and terminology",
    ).dependOn(gate_build.add(b, target));
}

/// The two internal peers the tests spawn as real second processes.
fn testPeers(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    cli: *std.Build.Module,
) [2]*std.Build.Step.Compile {
    var peers: [2]*std.Build.Step.Compile = undefined;
    const mains = [_][]const u8{
        "src/interfaces/cli/host_move_main.zig",
        "src/interfaces/cli/host_lifecycle_main.zig",
    };
    for (mains, 0..) |main_file, i| {
        peers[i] = b.addExecutable(.{
            .name = if (i == 0) "ra8_host_move_peer" else "ra8_host_lifecycle_peer",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path(main_file),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                    .imports = &.{.{ .name = "cli_app", .module = cli }},
                },
            ),
        });
    }
    return peers;
}

/// A tools/ program's module, shared by its executable and its tests.
fn toolModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    path: []const u8,
) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
}

/// tools/usbip_attach.zig attaches `--usbip PORT` the way usbip does and
/// checks the descriptor and the vendor loopback (RA8EMU-75 slice 5c).
fn usbipAttach(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const usbip_mod = b.createModule(.{
        .root_source_file = b.path("tools/usbip_attach.zig"),
        .target = target,
        .optimize = optimize,
    });
    usbip_mod.addImport(
        "usbip_client",
        b.createModule(.{ .root_source_file = b.path("src/interfaces/usbip/client.zig") }),
    );
    const usbip = b.addRunArtifact(b.addExecutable(.{ .name = "usbip_attach", .root_module = usbip_mod }));
    usbip.addPassthruArgs();
    b.step("usbip-attach", "Attach --usbip PORT and check it end to end: -- PORT").dependOn(&usbip.step);
}

fn configureTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    emu: *std.Build.Module,
    cli: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    move_peer: *std.Build.Step.Compile,
    lifecycle_peer: *std.Build.Step.Compile,
) void {
    // The gate executable and its tests share the scanner modules.
    const gate_mod = toolModule(b, target, optimize, "tools/gate.zig");
    // tools/terms.zig is the terminology half, tested the same way.
    const terms_mod = toolModule(b, target, optimize, "tools/terms.zig");

    // tools/example/table.zig prints the RA8EMU-66 pass table; the tests read
    // its parser through the same module the executable is built from.
    const table_mod = toolModule(b, target, optimize, "tools/example/table.zig");
    // The hil config sits outside tools/example/, so it comes in as a module.
    table_mod.addImport("hil_conf", toolModule(b, target, optimize, "tools/hil/conf.zig"));
    const table = b.addRunArtifact(b.addExecutable(.{ .name = "example_table", .root_module = table_mod }));
    table.addPassthruArgs();
    b.step("examples", "Print the example pass table: -- EMULATOR DIR [INSTRUCTIONS]").dependOn(&table.step);

    const imports: build_tests.Imports = .{
        .filter = b.option([]const u8, "test-filter", "Compile only tests whose name contains this text"),
        .emu = emu,
        .cli = cli,
        .gate = gate_mod,
        .terms = terms_mod,
        .table = table_mod,
    };
    const specs = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "ra8_tests", .root = "tests/all.zig" },
        .{ .name = "ra8_host_tests", .root = "tests/all_host.zig" },
    };
    var suites: [specs.len]*std.Build.Step.Compile = undefined;
    for (specs, &suites) |spec, *suite| {
        suite.* = build_tests.compile(
            b,
            spec.name,
            spec.root,
            target,
            optimize,
            imports,
            exe,
            move_peer,
            lifecycle_peer,
        );
    }
    build_tests.add(b, &suites, target, optimize, emu, &exe.step);
}

fn executable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    cli: *std.Build.Module,
    libs: modules_build.Libraries,
    peer_only: bool,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = if (peer_only) "ra8_host_move_peer" else "ra8_emulator",
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                if (peer_only)
                    "src/interfaces/cli/host_move_main.zig"
                else
                    "src/interfaces/cli/main.zig",
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "cli_app", .module = cli }, .{ .name = "ra8_host", .module = libs.host } },
        }),
    });
    b.installArtifact(exe);
    return exe;
}
