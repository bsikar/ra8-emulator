//! The NOR array behind XSPI0: what a program can and cannot do to a byte
//! that is already there.
//!
//! The part is an ISS1 IS25LX512M, 64 MiB, in 4 KiB sectors. Almost none of
//! it is ever touched: a run programs a journal header and a few pages and
//! leaves the other sixty-something megabytes erased. So the array is
//! sparse, one sector allocated the first time something is written into it
//! and freed again when an erase puts it back to 0xFF. A sector nobody holds
//! reads as erased, which is what a fresh part does.
//!
//! dev keeps the whole 64 MiB as one static array, inverted so the zero page
//! stands for the erased part and a warm reboot only has to sweep the dirty
//! prefix. That works, and it is the kind of trick a language with a BSS
//! invites. Here the sector map says the same thing without the inversion to
//! hold in your head, and a reset frees what it held rather than clearing it.
//!
//! NOR semantics are the point of this file. A program only ever clears
//! bits, so writing 0x0F over 0x33 leaves 0x03 and never restores a one; the
//! only way back to 0xFF is a sector erase. LevelX depends on exactly that:
//! it marks a block used by clearing a bit in a header it wrote earlier.
const std = @import("std");

/// The part this models.
pub const part = struct {
    /// 512 Mbit, the full IS25LX512M.
    pub const size: u32 = 0x400_0000;
    /// The erase unit of opcode 0x20.
    pub const sector_len: u32 = 0x1000;
    /// What an untouched byte reads as.
    pub const erased: u8 = 0xFF;
    /// The JEDEC triplet RDID answers with: manufacturer, type, capacity.
    pub const jedec = [3]u8{ 0x9D, 0x5A, 0x1A };

    pub fn sectorOf(address: u32) u32 {
        return address / sector_len;
    }

    pub fn holds(address: u32, len: u32) bool {
        return @as(u64, address) + @as(u64, len) <= @as(u64, size);
    }
};

const Sector = [part.sector_len]u8;

/// A sparse NOR array: the sectors something has written to, by sector
/// index. Everything else is erased.
pub const Flash = struct {
    allocator: std.mem.Allocator,
    sectors: std.AutoHashMap(u32, *Sector),

    pub fn init(allocator: std.mem.Allocator) Flash {
        return .{
            .allocator = allocator,
            .sectors = std.AutoHashMap(u32, *Sector).init(allocator),
        };
    }

    pub fn deinit(self: *Flash) void {
        self.release();
        self.sectors.deinit();
    }

    /// Sectors currently held. A run that only read the part holds none.
    pub fn live(self: *const Flash) u32 {
        return self.sectors.count();
    }

    /// The content byte at an address. Beyond the part, and in a sector
    /// nobody has written to, that is the erased value.
    pub fn byte(self: *const Flash, address: u32) u8 {
        if (address >= part.size) return part.erased;
        const sector = self.sectors.get(part.sectorOf(address)) orelse return part.erased;
        return sector[address % part.sector_len];
    }

    /// Program one byte: NOR clears bits and never sets them, so the stored
    /// value is what was there AND what was asked for. A byte that would
    /// change nothing does not make the model hold a sector for it.
    pub fn program(self: *Flash, address: u32, value: u8) !void {
        if (address >= part.size) return;
        const current = self.byte(address);
        const next = current & value;
        if (next == current) return;
        const sector = try self.hold(part.sectorOf(address));
        sector[address % part.sector_len] = next;
    }

    /// Erase the sector an address falls in, back to 0xFF. Dropping the
    /// sector is the erase: an absent one already reads erased.
    pub fn erase(self: *Flash, address: u32) void {
        if (address >= part.size) return;
        const index = part.sectorOf(address);
        if (self.sectors.fetchRemove(index)) |held| self.allocator.destroy(held.value);
    }

    /// Back to a fresh part, holding nothing.
    pub fn reset(self: *Flash) void {
        self.release();
        self.sectors.clearRetainingCapacity();
    }

    /// Free every sector the map is holding, leaving the map itself alone.
    fn release(self: *Flash) void {
        var held = self.sectors.valueIterator();
        while (held.next()) |sector| self.allocator.destroy(sector.*);
    }

    /// The sector for an index, allocated erased if this is the first write
    /// into it.
    fn hold(self: *Flash, index: u32) !*Sector {
        if (self.sectors.get(index)) |sector| return sector;
        const sector = try self.allocator.create(Sector);
        @memset(sector, part.erased);
        try self.sectors.put(index, sector);
        return sector;
    }
};
