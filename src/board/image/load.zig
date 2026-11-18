//! An ELF image read into the chip's loaded-image value (RA8EMU-1039,
//! RA8EMU-1343).
const elf = @import("elf.zig");
const loaded_image = @import("ra8_chip").core.loaded_image;
const machine_memory = @import("ra8_chip").core.machine.memory;
const pages = @import("pages.zig");

/// Load segments with file bytes one image may carry.
pub const capacity: usize = 32;

pub const Error = error{TooManySegments} || pages.Error;

pub const Loaded = struct {
    segments: [capacity]loaded_image.Segment = undefined,
    count: usize = 0,
    maps: pages.Set = .{},
    vector_base: ?u32 = null,

    pub fn image(self: *const Loaded) loaded_image.Image {
        return .{
            .segments = self.segments[0..self.count],
            .maps = self.maps.items(),
            .vector_base = self.vector_base,
        };
    }
};

/// The segments, merged pages and vector table of `source` for the default RA8 map.
pub fn read(source: elf.Image) Error!Loaded {
    return readFor(source, &machine_memory.ra8);
}

/// The segments, merged pages and vector table of `source` for `map`.
pub fn readFor(source: elf.Image, map: *const machine_memory.MemoryMap) Error!Loaded {
    var loaded = Loaded{ .maps = try pages.forImage(source), .vector_base = source.vectorBaseFor(map) };
    var index: u16 = 0;
    while (index < source.segmentCount()) : (index += 1) {
        const segment = source.loadSegment(index) orelse continue;
        if (loaded.count == capacity) return Error.TooManySegments;
        loaded.segments[loaded.count] = segment;
        loaded.count += 1;
    }
    return loaded;
}
