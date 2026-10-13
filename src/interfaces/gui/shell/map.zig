//! The shell's memory map leaf (RA8EMU-781): the loaded image's sections as
//! blocks over the board's linker regions, built when an image opens, with
//! the block the pointer rests on for the hover line. A click on a block
//! moves the memory leaf to the block's start.

const std = @import("std");
const ra8 = @import("ra8_session");
const map_layout = @import("../map_layout.zig");

const Image = ra8.symbols.Image;
const region_map = ra8.region.map;

/// Largest image read, as the loader reads it.
pub const max_image: usize = 64 * 1024 * 1024;

pub const State = struct {
    allocator: std.mem.Allocator,
    /// The io the image file reads through.
    io: std.Io = undefined,
    /// The image's bytes: the layout's names borrow them, so they live as
    /// long as the layout and are freed by the next build or deinit.
    bytes: ?[]u8 = null,
    /// The layout of the image in use; null until one builds.
    layout: ?map_layout.Layout = null,
    /// The block the pointer rests on, for the hover line.
    hover: ?usize = null,
    /// The last build failed; the map that was there stays.
    failed: bool = false,

    /// Read `path` and lay its sections over the board's regions.
    pub fn build(self: *State, path: []const u8) void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_image)) catch {
            self.failed = true;
            return;
        };
        const image = Image.init(bytes) catch {
            self.allocator.free(bytes);
            self.failed = true;
            return;
        };
        const layout = map_layout.build(image, &region_map.ek_ra8d2) catch {
            self.allocator.free(bytes);
            self.failed = true;
            return;
        };
        if (self.bytes) |old| self.allocator.free(old);
        self.bytes = bytes;
        self.layout = layout;
        self.failed = false;
    }

    pub fn deinit(self: *State) void {
        if (self.bytes) |old| self.allocator.free(old);
        self.bytes = null;
        self.layout = null;
    }
};
