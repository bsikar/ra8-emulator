//! The build for the RA8D2 board emulator.
//!
//! One language, one build. The emulator is Zig, CPU and disassembler
//! included; no C library is linked beyond libc, nothing here is exported
//! back to C and there is no C ABI of our own.
//!
//!   zig build         the emulator into zig-out/bin
//!   zig build run     build and run it
//!   zig build test    the unit tests under tests/
//!   zig build gate    zig fmt --check, then the file and function length
//!                     checks in tools/gate.zig
//!   zig build gui-hello -Dgui
//!                     the SDL3 hello window (RA8EMU-616); SDL is a lazy
//!                     dependency, fetched and built only with -Dgui
//!   zig build -Dgui   the emulator with SDL linked, so `--gui` opens a
//!                     window (RA8EMU-646)
//!
//! Source is grouped, not flat: src/core/ is the machine (engine, elf,
//! memmap and disasm), src/periph/ is everything that
//! answers on the peripheral bus, and src/main.zig sits on top. Tests live
//! in tests/ on mirrored paths, never in a `test` block at the bottom of a
//! source file, and tests/all.zig is the root that pulls them in.
//!
//! -Ddeps-prefix is accepted and ignored: the C library it pointed at is
//! gone (RA8EMU-706), and existing invocations keep building.
//!
//! Zig 0.14.1, the version pinned in ra8-firmware .devcontainer/Dockerfile.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.option([]const u8, "deps-prefix", "Ignored; kept so existing invocations still build");
    const gui = b.option(bool, "gui", "Fetch and build SDL3 for the GUI steps and `--gui`") orelse false;

    // One library module, reached as "ra8" by the executable and by the
    // tests, so neither has to walk relative paths into src/.
    const emu = b.addModule("ra8", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const firmware = b.dependency("ra8_firmware", .{});
    emu.addImport("ra8_rpc", firmware.module("ra8_rpc"));
    emu.addImport("ra8_widget", firmware.module("ra8_widget"));
    emu.addImport("ra8_widget_host", firmware.module("ra8_widget_host"));

    const exe = b.addExecutable(.{
        .name = "ra8_emulator",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("ra8", emu);
    const build_options = b.addOptions();
    build_options.addOption(bool, "gui", gui);
    exe.root_module.addOptions("build_options", build_options);
    exe.linkLibC();
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

    // tools/example_table.zig prints the RA8EMU-66 pass table; the tests read
    // its parser through the same module the executable is built from.
    const table_mod = b.createModule(.{
        .root_source_file = b.path("tools/example_table.zig"),
        .target = target,
        .optimize = optimize,
    });
    const table = b.addRunArtifact(b.addExecutable(.{ .name = "example_table", .root_module = table_mod }));
    if (b.args) |args| table.addArgs(args);
    b.step("examples", "Print the example pass table: -- EMULATOR DIR [INSTRUCTIONS]").dependOn(&table.step);

    usbipAttach(b, target, optimize);
    const bench_mod = handoffBench(b, target, optimize, emu);
    if (guiHello(b, target, optimize, emu, gui)) |sdl_mod| exe.root_module.addImport("gui_sdl", sdl_mod);

    const tests = b.addTest(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("ra8", emu);
    tests.root_module.addImport("ra8_widget", firmware.module("ra8_widget"));
    tests.root_module.addImport("gate", gate_mod);
    tests.root_module.addImport("example_table", table_mod);
    tests.root_module.addImport("handoff_bench", bench_mod);
    tests.linkLibC();
    const test_step = b.step("test", "Run the unit tests and compile the emulator");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    harnessChecks(b, target, optimize, emu, test_step, &exe.step);

    b.step("gate", "Check formatting and file and function length").dependOn(gate(b, target));
}

fn harnessChecks(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emu: *std.Build.Module, test_step: *std.Build.Step, exe_step: *std.Build.Step) void {
    const consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "run" });
    consumer.setCwd(b.path("tests/consumer"));
    const consumer_step = b.step("consumer-smoke", "Build and run the public harness consumer");
    consumer_step.dependOn(&consumer.step);
    test_step.dependOn(&consumer.step);
    test_step.dependOn(exe_step);
    const harness_tests = b.addTest(.{
        .root_source_file = b.path("tests/harness_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    harness_tests.root_module.addImport("ra8", emu);
    harness_tests.linkLibC();
    const harness_step = b.step("harness-test", "Run public harness behavior tests");
    harness_step.dependOn(&b.addRunArtifact(harness_tests).step);
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

/// tools/usbip_attach.zig attaches `--usbip PORT` the way usbip does and
/// checks the descriptor and the vendor loopback (RA8EMU-75 slice 5c).
fn usbipAttach(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const usbip_mod = b.createModule(.{
        .root_source_file = b.path("tools/usbip_attach.zig"),
        .target = target,
        .optimize = optimize,
    });
    usbip_mod.addImport("usbip_client", b.createModule(.{ .root_source_file = b.path("src/interfaces/usbip/usbip_client.zig") }));
    const usbip = b.addRunArtifact(b.addExecutable(.{ .name = "usbip_attach", .root_module = usbip_mod }));
    if (b.args) |args| usbip.addArgs(args);
    b.step("usbip-attach", "Attach --usbip PORT and check it end to end: -- PORT").dependOn(&usbip.step);
}

/// tools/handoff_bench.zig times the board snapshot handoff with and
/// without a 240 Hz reader (RA8EMU-227); the tests drive the same module.
fn handoffBench(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emu: *std.Build.Module) *std.Build.Module {
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/handoff_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("ra8", emu);
    const bench = b.addRunArtifact(b.addExecutable(.{ .name = "handoff_bench", .root_module = bench_mod }));
    bench.has_side_effects = true;
    b.step("bench-handoff", "Time the UI snapshot handoff against a 240 Hz reader (use -Doptimize=ReleaseFast)").dependOn(&bench.step);
    return bench_mod;
}

/// The SDL3 hello window (RA8EMU-616, docs/adr/0001-gui-stack.md). SDL is
/// a lazy dependency asked for only under -Dgui, so test and gate never
/// fetch or compile it. Without -Dgui the step says how. Returns the SDL
/// module, which the emulator also takes under -Dgui for `--gui`
/// (RA8EMU-646).
fn guiHello(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emu: *std.Build.Module, enabled: bool) ?*std.Build.Module {
    const step = b.step("gui-hello", "Build and open the SDL3 hello window (needs -Dgui): -- [--frames N]");
    if (!enabled) {
        step.dependOn(&b.addFail("gui-hello needs SDL3: run `zig build gui-hello -Dgui`").step);
        return null;
    }
    const sdl_dep = b.lazyDependency("sdl", .{ .target = target, .optimize = optimize }) orelse return null;
    const sdl_mod = b.createModule(.{ .root_source_file = b.path("src/gui/sdl.zig"), .target = target, .optimize = optimize });
    sdl_mod.addImport("ra8", emu);
    sdl_mod.linkLibrary(sdl_dep.artifact("SDL3"));
    const hello_mod = b.createModule(.{ .root_source_file = b.path("src/gui_hello.zig"), .target = target, .optimize = optimize });
    hello_mod.addImport("ra8", emu);
    hello_mod.addImport("gui_sdl", sdl_mod);
    const hello = b.addExecutable(.{ .name = "gui_hello", .root_module = hello_mod });
    const install = b.addInstallArtifact(hello, .{});
    step.dependOn(&install.step);
    // A cross build (x86_64-windows-gnu, aarch64-macos) only installs.
    if (!target.query.isNative()) return sdl_mod;
    const run = b.addRunArtifact(hello);
    run.step.dependOn(&install.step);
    if (b.args) |args| run.addArgs(args);
    step.dependOn(&run.step);
    return sdl_mod;
}
