//! Plug a disk into the USB stick the HS host sees, for one run. The jack
//! carries the echo device by default, which the self-loop examples talk
//! to; a host example that mounts a drive asks for a disk instead.
//!
//! "blank" is a freshly formatted FAT12 volume. Anything else is a path to
//! a raw image on the host, read whole into memory: the run writes to the
//! copy, never back to the file.
const std = @import("std");
const usb = @import("usb.zig");
const usb_disk = @import("../components/usb_stick/disk.zig");

pub const blank_spec = "blank";
/// 256 KiB: big enough for the host examples' files, and still FAT12.
pub const blank_len: usize = 512 * usb_disk.sector_len;
/// The largest image read from the host.
pub const max_image: usize = 64 * 1024 * 1024;
/// The serial stamped on a blank volume, so runs are repeatable.
pub const blank_serial: u32 = 0x5241_3845;

pub const Error = error{ EmptyImage, NotWholeSectors } || usb_disk.Error;

/// The disk bytes a spec names, owned by `allocator`.
pub fn load(allocator: std.mem.Allocator, io: std.Io, spec: []const u8) ![]u8 {
    if (std.mem.eql(u8, spec, blank_spec)) {
        const disk = try allocator.alloc(u8, blank_len);
        errdefer allocator.free(disk);
        _ = try usb_disk.format(disk, blank_serial);
        return disk;
    }
    const disk = try std.Io.Dir.cwd().readFileAlloc(io, spec, allocator, .limited(max_image));
    errdefer allocator.free(disk);
    if (disk.len == 0) return error.EmptyImage;
    if (disk.len % usb_disk.sector_len != 0) return error.NotWholeSectors;
    return disk;
}

/// Put `disk` in the stick and the stick behind the far-end device's bulk
/// endpoints. The board has to be at its final address: the device keeps a
/// pointer to the stick.
pub fn plug(board_usb: *usb.Usb, disk: []u8) void {
    board_usb.stick.disk = disk;
    board_usb.host.xfer.device.storage = board_usb.stick.function();
}

/// What the --usb-disk option asked for, if anything: load it and plug it
/// in, or say on stderr why not.
pub fn apply(board_usb: *usb.Usb, allocator: std.mem.Allocator, io: std.Io, spec: ?[]const u8) !void {
    const named = spec orelse return;
    const disk = load(allocator, io, named) catch |err| {
        std.debug.print("--usb-disk {s}: {s}\n", .{ named, @errorName(err) });
        return err;
    };
    plug(board_usb, disk);
}
