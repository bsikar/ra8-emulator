//! CPU1's image read from the host and handed to the chip (RA8EMU-1039).
//! The application reads the file, the board's loader parses it, and the
//! chip's CPU1 bring-up takes only the loaded value.
const std = @import("std");
const elf = @import("../../board/loader/elf.zig");
const loader = @import("../../board/loader/image.zig");
const second_core = @import("../../chip/core/second_core.zig");
const Driver = @import("../../chip/core/second_zig_run.zig").Driver;
const Wiring = @import("../../chip/core/second_wiring.zig").Wiring;
const Guest = @import("../../chip/core/cpu/memory/guest.zig").Guest;

/// Open `driver` on the image at `path`. The bytes are written into CPU1's
/// store before this returns, so they are freed here.
pub fn open(driver: *Driver, allocator: std.mem.Allocator, io: std.Io, wiring: Wiring, path: []const u8, memory: Guest) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(second_core.limits.image_bytes));
    defer allocator.free(bytes);
    const loaded = try loader.read(try elf.Image.init(bytes));
    try driver.open(wiring, loaded.image(), memory);
}
