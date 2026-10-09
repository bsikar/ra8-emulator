//! The chip's side of off-chip memory (ADR 0004 section 3, RA8EMU-1041).
//! The SDRAM and OSPI apertures decode here; the board supplies what sits
//! behind them as a Port: the SDRAM backing bytes, the mapped OSPI device
//! and a meter that charges each access to the board's timing model.
const mapped = @import("mapped.zig");
const Initiator = @import("initiator.zig").Initiator;

pub const Kind = enum(u1) {
    ospi,
    sdram,

    pub fn label(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn base(self: Kind) u32 {
        return switch (self) {
            .ospi => 0x8000_0000,
            .sdram => 0x6800_0000,
        };
    }
};

pub const Hit = struct {
    kind: Kind,
    offset: u32,
};

pub const Direction = enum { read, write };

pub const sdram_alias_base: u32 = 0x7800_0000;
pub const ospi_max: u32 = 256 * 1024 * 1024;
pub const sdram_max: u32 = 128 * 1024 * 1024;

/// The selected capacity behind each aperture.
pub const Geometry = struct {
    ospi: u32,
    sdram: u32,

    pub fn size(self: Geometry, kind: Kind) u32 {
        return switch (kind) {
            .ospi => self.ospi,
            .sdram => self.sdram,
        };
    }

    pub fn locate(self: Geometry, address: u32, len: usize) ?Hit {
        inline for (.{ Kind.ospi, Kind.sdram }) |kind| {
            const capacity = self.size(kind);
            if (holds(kind.base(), capacity, address, len)) return .{ .kind = kind, .offset = address - kind.base() };
            if (kind == .sdram and holds(sdram_alias_base, capacity, address, len)) {
                return .{ .kind = kind, .offset = address - sdram_alias_base };
            }
        }
        return null;
    }

    /// Whether any byte of a non-empty span intersects a configured external
    /// aperture, including SDRAM's Non-secure alias.
    pub fn overlaps(self: Geometry, address: u32, len: usize) bool {
        if (len == 0) return false;
        inline for (.{ Kind.ospi, Kind.sdram }) |kind| {
            const capacity = self.size(kind);
            if (overlap(kind.base(), capacity, address, len)) return true;
            if (kind == .sdram and overlap(sdram_alias_base, capacity, address, len)) return true;
        }
        return false;
    }
};

/// Whether a span intersects any controller-supported external aperture,
/// including a disabled tail beyond the selected capacity.
pub fn supportedOverlap(address: u32, len: usize) bool {
    return overlap(Kind.ospi.base(), ospi_max, address, len) or
        overlap(Kind.sdram.base(), sdram_max, address, len) or
        overlap(sdram_alias_base, sdram_max, address, len);
}

/// Charges one access to whatever timing model the board keeps.
pub const Meter = struct {
    context: *anyopaque,
    charge: *const fn (context: *anyopaque, initiator: Initiator, hit: Hit, direction: Direction, len: usize) void,

    pub inline fn note(self: Meter, initiator: Initiator, hit: Hit, direction: Direction, len: usize) void {
        self.charge(self.context, initiator, hit, direction, len);
    }
};

/// What the board puts behind the SDRAM and OSPI apertures. SDRAM reads and
/// writes are plain copies into `sdram`; OSPI goes through the device so its
/// erased state and program rules hold.
pub const Port = struct {
    geometry: Geometry,
    sdram: []u8,
    flash: mapped.Mapped,
    meter: Meter,
};

fn holds(base: u32, size: u32, address: u32, len: usize) bool {
    if (address < base) return false;
    const offset = @as(u64, address) - base;
    return offset + len <= size;
}

fn overlap(base: u32, size: u32, address: u32, len: usize) bool {
    const first = @as(u64, address);
    const last = first + len;
    const region_first = @as(u64, base);
    const region_last = region_first + size;
    return first < region_last and last > region_first;
}
