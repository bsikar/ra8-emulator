//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Links the UI firmware image. The UI is one Zig object; everything under
//! it is ra8-firmware's: the board's boot units and linker script, the C
//! HAL, and the migrated Zig archives. Which sources, flags and include
//! paths an app gets is decided by the firmware's own build-graph rules,
//! imported from its build.zig, so this file only strings them together the
//! way the firmware's `zig build arm` does for an app in its own tree.

const std = @import("std");
const fw = @import("ra8_firmware");

const sources = fw.cross_sources;
const arm = fw.arm_flags;

pub const name = "ra8_ui";

/// The UI as the firmware's rules see it: an app outside the firmware tree
/// (paths are relative to the firmware root) with a Zig main, the board's
/// touch support, the SPI bus facade and the VCOM policy.
const app: sources.CrossApp = .{
    .name = name,
    .dir = "../board",
    .board = "libs/ra8_board_ek_ra8d2",
    .linker_script = "libs/ra8_board_ek_ra8d2/ld/linker_script.ld",
    .libraries = &.{ "ra8_board_ek_ra8d2", "ra8_io_bus", "ra8_epd_cal" },
    .zig_libraries = &.{},
    .zig_main = "src/main.zig",
};

/// The Zig archives every image links, then the ones this app adds.
const archives = [_][]const u8{ "ra8_core", "ra8_usb_pal", "ra8_hal", "ra8_board_ek_ra8d2", "if_ra8_cgc", "if", "ra8_epd_cal", "ra8_io" };

/// The UI rebuilds a screen on the stack it is called on; the board's
/// default 8K is sized for a blink loop.
const stack_size = "64K";

/// The two fragments the board linker script includes, as an app that
/// changes nothing about the memory map gets them.
const fragments = [_][2][]const u8{
    .{ "ra8_app_pre_memory.ld", "/* ra8-ui: board memory map used as written. */\n" },
    .{ "ra8_app_pre_text.ld", "/* ra8-ui: nothing to inject ahead of .text. */\n" },
};

/// Where the Arm GNU Toolchain 13.3 lives unless `-Darm-gnu-toolchain`
/// says otherwise: the same default and option name the firmware uses. An
/// older arm-none-eabi-gcc found on PATH first would reject the cortex-m85.
pub const toolchain = struct {
    pub const option = "arm-gnu-toolchain";
    pub const default_dir = "/opt/arm-gnu-toolchain-13.3/bin";
};

const Tools = fw.cross_build.Tools;

fn tool(b: *std.Build, dir: []const u8, comptime program: []const u8) ?[]const u8 {
    const path = b.pathJoin(&.{ dir, "arm-none-eabi-" ++ program });
    std.fs.accessAbsolute(path, .{}) catch return null;
    return path;
}

/// The cross tools in `dir`, or whatever PATH has when `dir` lacks them.
fn findTools(b: *std.Build, dir: []const u8) ?Tools {
    return .{
        .gcc = tool(b, dir, "gcc") orelse return fw.cross_build.findTools(b),
        .objcopy = tool(b, dir, "objcopy") orelse return fw.cross_build.findTools(b),
        .size = tool(b, dir, "size") orelse return fw.cross_build.findTools(b),
        .ar = tool(b, dir, "ar") orelse return fw.cross_build.findTools(b),
    };
}

pub const Target = struct {
    resolved: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// The target the firmware builds an M85 app's Zig for.
pub fn target(b: *std.Build) Target {
    return .{ .resolved = b.resolveTargetQuery(sources.zig_target_query), .optimize = .ReleaseSmall };
}

fn compile(fwb: *std.Build, tools: Tools, globals: fw.build_type.Globals, source: []const u8, include_dirs: []const []const u8) std.Build.LazyPath {
    const run = fwb.addSystemCommand(&.{tools.gcc});
    run.addArgs(&arm.cpu_flags);
    run.addArgs(fw.device.compileFlags(app.board));
    run.addArgs(globals.config_flags);
    run.addArgs(&arm.dialect_flags);
    if (sources.isOffTargetSource(app, source)) run.addArg(sources.off_target_define);
    run.addArgs(arm.warningFlags(fwb.allocator, app));
    run.addArgs(&arm.target_dialect_flags);
    for (include_dirs) |dir| run.addPrefixedDirectoryArg("-I", fwb.path(dir));
    run.addArg("-c");
    run.addFileArg(fwb.path(source));
    run.addArg("-o");
    return run.addOutputFileArg(fwb.fmt("{s}.o", .{std.fs.path.basename(source)}));
}

fn bootObject(fwb: *std.Build, unit: []const u8, t: Target) std.Build.LazyPath {
    const module = fwb.createModule(.{ .root_source_file = fwb.path(unit), .target = t.resolved, .optimize = t.optimize, .unwind_tables = .none });
    const options = fwb.addOptions();
    const values = sources.bootOptions(app);
    inline for (std.meta.fields(sources.BootOptions)) |field| options.addOption(field.type, field.name, @field(values, field.name));
    module.addOptions("boot_options", options);
    return fwb.addObject(.{ .name = fwb.fmt("{s}_{s}", .{ name, std.fs.path.stem(unit) }), .root_module = module }).getEmittedBin();
}

/// Link `main_object` into `ra8_ui.elf` and install it under zig-out/image.
/// `firmware` is the ra8-firmware dependency.
pub fn add(b: *std.Build, step: *std.Build.Step, firmware: *std.Build.Dependency, main_object: std.Build.LazyPath, t: Target) void {
    const fwb = firmware.builder;
    const dir = b.option([]const u8, toolchain.option, "Arm GNU Toolchain 13.3 bin directory (default " ++ toolchain.default_dir ++ ")") orelse toolchain.default_dir;
    const tools = findTools(b, dir) orelse {
        step.dependOn(&b.addFail("image: no arm-none-eabi toolchain in " ++ toolchain.default_dir ++ " or on PATH").step);
        return;
    };
    const globals = fw.build_type.globals(b.allocator, .relwithdebinfo, fw.cross_image.base());
    const include_dirs = sources.crossIncludeDirs(fwb, app);

    const link = fwb.addSystemCommand(&.{tools.gcc});
    link.addArgs(&arm.cpu_flags);
    link.addArgs(fw.device.linkFlags(app.board));
    link.addArgs(globals.config_flags);
    link.addArgs(&arm.link_flags);
    link.addArg(b.fmt("-Wl,--defsym=g_ra8_ls_stack_size={s}", .{stack_size}));
    const fragment_files = b.addWriteFiles();
    for (fragments) |fragment| _ = fragment_files.add(fragment[0], fragment[1]);
    link.addPrefixedDirectoryArg("-L", fragment_files.getDirectory());
    link.addPrefixedFileArg("-T", fwb.path(app.linker_script));
    const map = link.addPrefixedOutputFileArg("-Wl,--Map=", name ++ ".map");
    link.addArg("-o");
    const elf = link.addOutputFileArg(name ++ ".elf");
    link.addFileArg(main_object);
    for (sources.crossBootZigUnits(fwb, app)) |unit| link.addFileArg(bootObject(fwb, unit, t));
    for (sources.crossSources(fwb, app)) |source| link.addFileArg(compile(fwb, tools, globals, source, include_dirs));
    link.addArg("-Wl,--start-group");
    for (archives) |library| {
        const dependency = fwb.dependency(library, .{ .target = t.resolved, .optimize = globals.configuration.zig_optimize });
        link.addFileArg(dependency.artifact(library).getEmittedBin());
    }
    link.addArg("-Wl,--end-group");
    link.addArg("-lgcc");

    const install_dir: std.Build.InstallDir = .{ .custom = "image" };
    step.dependOn(&b.addInstallFileWithDir(elf, install_dir, name ++ ".elf").step);
    step.dependOn(&b.addInstallFileWithDir(map, install_dir, name ++ ".map").step);
    const size = b.addSystemCommand(&.{tools.size});
    size.addFileArg(elf);
    step.dependOn(&size.step);
}
