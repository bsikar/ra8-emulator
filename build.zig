//! The build for the RA8D2 board emulator.
//!
//! The emulator, CPU and disassembler use Zig. Only libc links to C;
//! nothing is exported back to C and there is no C ABI of our own.
//!
//!    zig build          the emulator into zig-out/bin
//!    zig build run      build and run it
//!    zig build run-gui -Dgui -- IMAGE
//!                       build and run ra8_gui on IMAGE
//!    zig build test     the unit tests under tests/
//!    zig build gate     zig fmt --check, then the file and function length
//!                       checks in tools/gate.zig
//!    zig build -Dgui    also ra8_gui, the debugger shell in an SDL window;
//!                       SDL is a lazy dependency, fetched and built only
//!                       with -Dgui
//!
//! The source is ten libraries and two applications, each a build module
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
//!    src/interfaces/cli/      cli_app          ra8_emulator, which never links SDL
//!    src/interfaces/gui/      gui_app          ra8_gui, built under -Dgui
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
const gui_smoke = @import("tools/gui_smoke.zig");
const lint_build = @import("tools/lint/build.zig");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gui = b.option(bool, "gui", "Fetch SDL3 and build ra8_gui and the GUI tests") orelse false;
    const peer_only = b.option(
        bool,
        "host-move-peer-only",
        "Build the internal native directory move peer",
    ) orelse false;

    const system_include_path = b.option(
        []const u8,
        "system_include_path",
        "Host/sysroot path to C headers for cross-compilation",
    );
    const system_framework_path = b.option(
        []const u8,
        "system_framework_path",
        "Host/sysroot path to Apple frameworks for cross-compilation",
    );
    const library_path = b.option([]const u8, "library_path", "Host/sysroot path to C libraries for cross-compilation");

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
    const apps = modules_build.applications(b, target, optimize, libs, firmware);

    const exe = executable(b, target, optimize, apps, libs, peer_only);
    const peers = testPeers(b, target, optimize, apps.cli);
    const move_peer = if (peer_only) exe else peers[0];
    const lifecycle_peer = peers[1];

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the emulator").dependOn(&run.step);

    debug_build.add(b);
    usbipAttach(b, target, optimize);
    const sdl_mod = sdlModule(
        b,
        target,
        optimize,
        apps.gui,
        libs.render,
        gui,
        system_include_path,
        system_framework_path,
        library_path,
    );
    const gui_exe = if (sdl_mod) |mod|
        guiExe(b, target, optimize, apps.gui, libs.host, mod, system_framework_path)
    else
        null;
    guiTest(b, target, optimize, emu, gui, sdl_mod, gui_exe);
    runGui(b, gui_exe);
    lint_build.add(b, @This());

    configureTests(b, target, optimize, emu, apps, firmware, exe, move_peer, lifecycle_peer);

    b.step("gate", "Check formatting, file and function length, and terminology").dependOn(gate_build.add(b, target));
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

/// The SDL3 backend module (src/interfaces/gui/sdl/sdl.zig, RA8EMU-616, ADR 0001 in the
/// knowledge base, RA8EMU-A-8) that ra8_gui and gui-test take under
/// -Dgui. It draws what gui_app hands it and imports nothing else of ours
/// but the render library. SDL is a lazy dependency asked for only under -Dgui, so test and
/// gate never fetch or compile it.
fn sdlModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gui_app: *std.Build.Module,
    render: *std.Build.Module,
    enabled: bool,
    system_include_path: ?[]const u8,
    system_framework_path: ?[]const u8,
    library_path: ?[]const u8,
) ?*std.Build.Module {
    if (!enabled) return null;
    const sdl_dep = b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .system_include_path = system_include_path,
        .system_framework_path = system_framework_path,
        .library_path = library_path,
    }) orelse return null;
    const sdl_mod = b.createModule(
        .{
            .root_source_file = b.path("src/interfaces/gui/sdl/sdl.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    sdl_mod.addImport("gui_app", gui_app);
    sdl_mod.addImport("ra8_render", render);
    sdl_mod.linkLibrary(sdl_dep.artifact("SDL3"));
    sdl_mod.addImport("sdl3", sdlTranslation(b, target, optimize, sdl_dep.artifact("SDL3")));
    return sdl_mod;
}

/// SDL3's C API as a Zig module, translated by the translate-c package
/// (0.17 has no @cImport) against the SDL3 artifact's headers.
fn sdlTranslation(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdl: *std.Build.Step.Compile,
) *std.Build.Module {
    const header = b.addWriteFiles().add("sdl3.h", "#include <SDL3/SDL.h>\n");
    const translator: Translator = .init(
        b.dependency("translate_c", .{}),
        .{ .c_source_file = header, .target = target, .optimize = optimize },
    );
    translator.linkLibrary(sdl);
    return translator.mod;
}

/// ra8_gui (RA8EMU-1087, ADR 0004 step 6): the debugger shell in its SDL
/// window, installed next to ra8_emulator in a -Dgui build.
fn guiExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gui_app: *std.Build.Module,
    host: *std.Build.Module,
    sdl: *std.Build.Module,
    system_framework_path: ?[]const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "ra8_gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/interfaces/gui/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "gui_app", .module = gui_app },
                .{ .name = "gui_sdl", .module = sdl },
                .{ .name = "ra8_host", .module = host },
            },
        }),
    });
    if (system_framework_path) |fpath| {
        exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = fpath });
    }
    b.installArtifact(exe);
    return exe;
}

/// `zig build run-gui -Dgui -- IMAGE`: ra8_gui on the image, the GUI's
/// counterpart to `run`. Without -Dgui there is no ra8_gui to run.
fn runGui(b: *std.Build, gui_exe: ?*std.Build.Step.Compile) void {
    const step = b.step("run-gui", "Run the debugger GUI: -- IMAGE (needs -Dgui)");
    const exe = gui_exe orelse {
        step.dependOn(&b.addFail("run-gui needs SDL3: run `zig build run-gui -Dgui -- IMAGE`").step);
        return;
    };
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    step.dependOn(&run.step);
}

/// The SDL-backed GUI tests (RA8EMU-733): the geometry presenter against
/// the CPU golden on SDL's software renderer, the file picker's handoff
/// through SDL's event queue (RA8EMU-959), then the smoke run
/// (RA8EMU-1089), all headless. Kept out of `zig build test` so the tests
/// need no SDL.
fn guiTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    emu: *std.Build.Module,
    enabled: bool,
    sdl_mod: ?*std.Build.Module,
    gui_exe: ?*std.Build.Step.Compile,
) void {
    const step = b.step("gui-test", "Run the SDL-backed GUI tests and the ra8_gui --frames smoke run (needs -Dgui)");
    if (!enabled) {
        step.dependOn(&b.addFail("gui-test needs SDL3: run `zig build gui-test -Dgui`").step);
        return;
    }
    const sdl = sdl_mod orelse return;
    for ([_][]const u8{
        "tests/interfaces/gui/sdl/geometry_test.zig",
        "tests/interfaces/gui/sdl/dialog_test.zig",
    }) |root| {
        const mod = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize });
        mod.addImport("ra8", emu);
        mod.addImport("gui_sdl", sdl);
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }
    if (gui_exe) |exe| step.dependOn(gui_smoke.smoke(b, exe));
}

fn configureTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    emu: *std.Build.Module,
    apps: modules_build.Apps,
    firmware: *std.Build.Dependency,
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
        .cli = apps.cli,
        .gui = apps.gui,
        .widget = firmware.module("ra8_widget"),
        .gate = gate_mod,
        .terms = terms_mod,
        .table = table_mod,
    };
    const specs = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "ra8_tests", .root = "tests/all.zig" },
        .{ .name = "ra8_host_tests", .root = "tests/all_host.zig" },
        .{ .name = "ra8_gui_link_tests", .root = "tests/interfaces/gui/link_test.zig" },
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
    apps: modules_build.Apps,
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
            .imports = &.{ .{ .name = "cli_app", .module = apps.cli }, .{ .name = "ra8_host", .module = libs.host } },
        }),
    });
    b.installArtifact(exe);
    return exe;
}
