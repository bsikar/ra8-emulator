//! ra8_emulator: the RA8D2 board emulator's command line (#14, the Zig
//! rewrite; moved here from src/main.zig by RA8EMU-1087, ADR 0004 step 6).
//! It never links SDL and imports nothing from the GUI: the window and its
//! debugger shell are ra8_gui (src/interfaces/gui/main.zig).
//!
//! This file opens the ELF and hands the run to the Zig core
//! (src/interfaces/cli/zig_main.zig). A debugger command line goes to the
//! debug front instead. The machine and its peripherals live in src/chip/core
//! and src/chip/periph, reached through "ra8".
const std = @import("std");
const ra8 = @import("ra8");

const cli = ra8.core.cli;

// A macOS build carries the Info.plist the camera permission needs.
comptime {
    _ = ra8.host.camera.av_info_plist;
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
    const options = cli.parse(argv) catch return ra8.core.debug_front.refused(allocator, io, argv);
    const image = ra8.image.file.open(io, allocator, options.path) catch return 1;
    return ra8.board.zig_run.main_path.run(allocator, io, image, options);
}
