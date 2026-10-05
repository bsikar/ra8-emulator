//! The build for the RA8D2 board emulator.
//!
//! One language, one build. The emulator is Zig, CPU included; Capstone
//! (error-path disassembly) is the one C library left, reached through a
//! single @cImport in src/core/c.zig. Nothing here is exported back to C and
//! there is no C ABI of our own.
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
//! memmap, disasm and the one C boundary), src/periph/ is everything that
//! answers on the peripheral bus, and src/main.zig sits on top. Tests live
//! in tests/ on mirrored paths, never in a `test` block at the bottom of a
//! source file, and tests/all.zig is the root that pulls them in.
//!
//! Point the build at Capstone with -Ddeps-prefix=<prefix> when it is not on
//! the system paths.
//!
//! Zig 0.14.1, the version pinned in ra8-firmware .devcontainer/Dockerfile.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const prefix = b.option([]const u8, "deps-prefix", "Prefix holding include/ and lib/ for capstone");
    const gui = b.option(bool, "gui", "Fetch and build SDL3 for the GUI steps and `--gui`") orelse false;

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
    const build_options = b.addOptions();
    build_options.addOption(bool, "gui", gui);
    exe.root_module.addOptions("build_options", build_options);
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

    const parity_mod = disasmParity(b, target, optimize, emu, prefix);
    usbipAttach(b, target, optimize);
    if (guiHello(b, target, optimize, emu, gui)) |sdl_mod| exe.root_module.addImport("gui_sdl", sdl_mod);

    const tests = b.addTest(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("ra8", emu);
    tests.root_module.addImport("gate", gate_mod);
    tests.root_module.addImport("example_table", table_mod);
    tests.root_module.addImport("disasm_parity", parity_mod);
    link(b, tests, prefix);
    const test_step = b.step("test", "Run the unit tests and compile the emulator");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&exe.step);

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
    c.linkSystemLibrary("capstone");
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

/// tools/disasm_parity.zig compares our disassembler with Capstone over
/// ELFs (RA8EMU-325); the tests drive its walker through the same module.
fn disasmParity(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, emu: *std.Build.Module, prefix: ?[]const u8) *std.Build.Module {
    const parity_mod = b.createModule(.{
        .root_source_file = b.path("tools/disasm_parity.zig"),
        .target = target,
        .optimize = optimize,
    });
    parity_mod.addImport("ra8", emu);
    const parity_exe = b.addExecutable(.{ .name = "disasm_parity", .root_module = parity_mod });
    link(b, parity_exe, prefix);
    const parity = b.addRunArtifact(parity_exe);
    if (b.args) |args| parity.addArgs(args);
    b.step("parity", "Compare our disassembler with Capstone: -- ELF...").dependOn(&parity.step);
    return parity_mod;
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
