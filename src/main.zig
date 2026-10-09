//! ra8_emulator: the RA8D2 board emulator (#14, the Zig rewrite).
//!
//! This file opens the ELF and hands the run to the Zig core
//! (src/interfaces/cli/zig_main.zig). A debugger command line goes to the
//! debug front instead. The machine and its peripherals live in src/chip/core
//! and src/chip/periph, reached through "ra8".
const std = @import("std");
const ra8 = @import("ra8");
const build_options = @import("build_options");

const cli = ra8.core.cli;

// A macOS build carries the Info.plist the camera permission needs.
comptime {
    _ = ra8.host.camera.av_info_plist;
}
const elf = ra8.board.elf;

/// Read the image off disk and parse it, saying which of the two failed.
fn openImage(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !elf.Image {
    const bytes = try readImage(io, allocator, path);
    return elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len >= 3 and std.mem.eql(u8, argv[1], "ctl") and std.mem.eql(u8, argv[2], "probe")) return ra8.core.probe_ctl.run(allocator, io, argv);
    if (argv.len >= 3 and std.mem.eql(u8, argv[1], "ctl") and (std.mem.eql(u8, argv[2], "--connect") or std.mem.eql(u8, argv[2], "--host"))) return ra8.core.session_ctl.run(allocator, io, init.environ_map, argv);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--map")) return ra8.core.map_main.run(allocator, io, argv);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "serve")) return ra8.core.serve_main.run(allocator, io, argv);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "sweep")) return ra8.core.sweep_cli.run(io, init.environ_map, argv);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "shell")) return shell(allocator, io, init.environ_map, argv);
    const options = cli.parse(argv) catch return ra8.core.debug_front.refused(allocator, io, argv);
    const image = openImage(io, allocator, options.path) catch return 1;
    // Only a -Dgui build compiles src/interfaces/gui/gui_window.zig and links SDL.
    if (build_options.gui) ra8.board.window_main.opener = @import("interfaces/gui/gui_window.zig").opener;
    return ra8.board.zig_run.main_path.run(allocator, io, image, options);
}

/// The docked debugger shell, in this build's window when it has one.
fn shell(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8) !u8 {
    if (build_options.gui) ra8.board.window_main.opener = @import("interfaces/gui/gui_window.zig").opener;
    return ra8.core.shell_main.run(allocator, io, env, argv);
}

/// The file behind `path`, or a printed complaint and the error that caused
/// it. The bytes outlive the file and are owned by the caller's arena.
fn readImage(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}
