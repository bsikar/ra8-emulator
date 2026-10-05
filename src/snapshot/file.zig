//! The snapshot file (RA8EMU-561, RA8EMU-659): a magic, a format version,
//! then sections. Each section is a kind and a length ahead of its bytes,
//! so a later slice (CPU state, peripheral state) adds a kind without
//! breaking a reader that does not know it: an unknown kind is skipped. An
//! unknown version is refused, since its sections may mean something else.
//!
//! Every number is little-endian.
const std = @import("std");

pub const magic = "RA8SNAP\x00".*;
/// Version 2 widens the IT8951 data cursor in the panel section.
pub const version: u32 = 2;

pub const Error = error{ BadMagic, BadVersion, Truncated };

/// What a section holds. Values are part of the format and never reused.
pub const Kind = enum(u32) {
    memory = 1,
    /// One core's architectural state (RA8EMU-658).
    cpu = 2,
    /// The virtual time base and its event queue (RA8EMU-661).
    time = 3,
    /// The board's timer units (RA8EMU-662).
    timers = 4,
    /// The board's SCI channels and line buffer (RA8EMU-663).
    serial = 5,
    /// The SPI-mode SD card and the SD host controller's card (RA8EMU-664).
    sd = 6,
    /// The I2C wire: RIIC, the I3C touch line and their parts (RA8EMU-666).
    wire = 7,
    /// The DRW 2D engine (RA8EMU-667).
    raster = 8,
    /// The GLCDC display controller (RA8EMU-668).
    display = 9,
    /// The e-paper panel (RA8EMU-669).
    panel = 10,
    /// The clock generation units and their protection (RA8EMU-670).
    clocks = 11,
    /// Security attribution, MPU, SAU and system control (RA8EMU-671).
    security = 12,
    /// The fixed-size memory controllers (RA8EMU-672).
    controllers = 13,
    /// The option MRAM and the xSPI flash with their sparse contents (RA8EMU-674).
    storage = 14,
    /// The self-contained data path units (RA8EMU-675).
    signals = 15,
    /// The data path units that carry wiring (RA8EMU-676).
    datapath = 16,
    /// The self-contained media and comms units (RA8EMU-678).
    media = 17,
    /// The media and comms units with top-level wiring (RA8EMU-679).
    wired = 18,
    /// The units with wiring in their channel arrays (RA8EMU-681).
    channels = 19,
    /// The board's USB side (RA8EMU-682).
    usb = 20,
    /// The Ethernet switch (RA8EMU-683).
    rswitch = 21,
    /// The NPU (RA8EMU-685).
    npu = 22,
    /// The ESP32-C6 companion (RA8EMU-687).
    c6 = 23,
    /// Which part the board was (RA8EMU-688); a load refuses another part.
    part = 24,
    /// The run's secure and Non-secure SysTick time bases (RA8EMU-694).
    systick = 25,
    /// What the run owed its clocks when it saved (RA8EMU-700).
    stretch = 26,
    _,
};

pub const Section = struct {
    kind: Kind,
    payload: []const u8,
};

pub fn writeHeader(writer: anytype) !void {
    try writer.writeAll(&magic);
    try writer.writeInt(u32, version, .little);
}

/// The section's kind and length; its `len` payload bytes follow.
pub fn writeSectionHeader(writer: anytype, kind: Kind, len: u64) !void {
    try writer.writeInt(u32, @intFromEnum(kind), .little);
    try writer.writeInt(u64, len, .little);
}

/// Walks the sections of a whole snapshot held in memory.
pub const Reader = struct {
    bytes: []const u8,
    at: usize,

    /// Checks the magic and version.
    pub fn open(bytes: []const u8) Error!Reader {
        if (bytes.len < magic.len) return Error.Truncated;
        if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return Error.BadMagic;
        var self: Reader = .{ .bytes = bytes, .at = magic.len };
        if (try self.int(u32) != version) return Error.BadVersion;
        return self;
    }

    /// The next section, or null at the end.
    pub fn next(self: *Reader) Error!?Section {
        if (self.at == self.bytes.len) return null;
        const kind: Kind = @enumFromInt(try self.int(u32));
        const len = try self.int(u64);
        if (len > self.bytes.len - self.at) return Error.Truncated;
        const payload = self.bytes[self.at..][0..@intCast(len)];
        self.at += payload.len;
        return .{ .kind = kind, .payload = payload };
    }

    /// The first section of `kind`, or null when there is none.
    pub fn find(bytes: []const u8, kind: Kind) Error!?Section {
        var reader = try open(bytes);
        while (try reader.next()) |section| {
            if (section.kind == kind) return section;
        }
        return null;
    }

    fn int(self: *Reader, comptime T: type) Error!T {
        const size = @sizeOf(T);
        if (self.bytes.len - self.at < size) return Error.Truncated;
        const value = std.mem.readInt(T, self.bytes[self.at..][0..size], .little);
        self.at += size;
        return value;
    }
};
