//! The SDL window `--gui` opens in a -Dgui build (RA8EMU-646). src/main.zig
//! hands this opener to src/interfaces/cli/window_main.zig; nothing else
//! imports it, so a build without -Dgui never compiles it or links SDL.
//! It has no unit test: `zig build test` has no SDL.
//! The board it draws is covered through the headless platform.
const ra8 = @import("ra8");
const sdl = @import("gui_sdl");

const Platform = ra8.gui.platform.Platform;

/// Tall enough for the board view (696 px) and about twenty console rows
/// under it (RA8EMU-206).
const width: u32 = 1280;
const height: u32 = 860;

/// The one window a run opens, alive from open until close.
var backend: ?sdl.Sdl = null;

pub const opener: ra8.board.window_main.Opener = .{ .open = open, .close = close };

fn open() ?Platform {
    backend = sdl.Sdl.init("ra8 emulator", width, height) catch return null;
    if (backend) |*window| return window.platform();
    return null;
}

fn close() void {
    if (backend) |*window| window.deinit();
    backend = null;
}
