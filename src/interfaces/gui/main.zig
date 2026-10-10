//! ra8_gui: the RA8D2 board emulator with its window (RA8EMU-1087, ADR 0004
//! step 6), built only under -Dgui. It hands the SDL opener
//! (gui_window.zig) to window_main and its live run (window_live.zig) to
//! zig_main, then runs the docked debugger shell (`ra8_gui shell ...`) or an
//! image in the live board window (`ra8_gui <elf> [run options]`). The command line, ra8_emulator, never
//! links SDL.
const std = @import("std");
const ra8 = @import("ra8");
const gui_window = @import("gui_window.zig");

// A macOS build carries the Info.plist the camera permission needs.
comptime {
    _ = ra8.host.camera.av_info_plist;
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(allocator);
    ra8.board.window_main.opener = gui_window.opener;
    ra8.board.zig_run.main_path.window = ra8.board.window_live.show;
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "shell")) return ra8.core.shell_main.run(allocator, io, init.environ_map, argv);
    const options = ra8.core.cli.parse(argv) catch return ra8.core.debug_front.refused(allocator, io, argv);
    const image = ra8.image.file.open(io, allocator, options.path) catch return 1;
    return ra8.board.zig_run.main_path.run(allocator, io, image, options);
}
