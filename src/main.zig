//! ra8_emulator: the RA8D2 board emulator (#14, the Zig rewrite).
//!
//! This file opens the ELF and hands the run to the Zig core
//! (src/interfaces/cli/zig_main.zig). A debugger command line goes to the
//! debug front instead. The machine and its peripherals live in src/core
//! and src/periph, reached through "ra8".
const std = @import("std");
const ra8 = @import("ra8");
const build_options = @import("build_options");

const cli = ra8.core.cli;
const elf = ra8.core.elf;

/// Read the image off disk and parse it, saying which of the two failed.
fn openImage(allocator: std.mem.Allocator, path: []const u8) !elf.Image {
    const bytes = try readImage(allocator, path);
    return elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const argv = try std.process.argsAlloc(allocator);
    const options = cli.parse(argv) catch return ra8.core.debug_front.refused(allocator, argv);
    const image = openImage(allocator, options.path) catch return 1;
    // Only a -Dgui build compiles src/gui_window.zig and links SDL.
    if (build_options.gui) ra8.board.window_main.opener = @import("gui_window.zig").opener;
    return ra8.board.zig_run.main_path.run(allocator, image, options);
}

/// The file behind `path`, or a printed complaint and the error that caused
/// it. The bytes outlive the file and are owned by the caller's arena.
fn readImage(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024 * 1024);
}
