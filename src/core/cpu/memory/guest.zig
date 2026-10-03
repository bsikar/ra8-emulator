//! One handle on guest memory, whichever backend holds it: the Unicorn
//! engine or the Zig core's own store. Board, peripheral and report code
//! take a Guest so they run unchanged on both (RA8EMU-481); the engine arm
//! goes when the engine does (RA8EMU-482).
const std = @import("std");
const engine = @import("../../engine.zig");
const code_lines = @import("../code_lines.zig");
const Store = @import("store.zig").Store;

pub const Error = error{Unmapped};

/// A map refused: the range is already backed, or the store is out of room.
pub const MapError = error{ Mapped, Full, OutOfMemory };

pub const Guest = union(enum) {
    engine: engine.Engine,
    store: *Store,

    pub fn read(self: Guest, address: u32, into: []u8) Error!void {
        if (into.len == 0) return;
        switch (self) {
            .engine => |core| core.read(address, into) catch return Error.Unmapped,
            .store => |memory| {
                const bytes = memory.span(address, into.len) orelse return Error.Unmapped;
                @memcpy(into, bytes);
            },
        }
    }

    pub fn write(self: Guest, address: u32, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        switch (self) {
            .engine => |core| core.write(address, bytes) catch return Error.Unmapped,
            .store => |memory| {
                const into = memory.span(address, bytes.len) orelse return Error.Unmapped;
                code_lines.notify(address, bytes.len);
                @memcpy(into, bytes);
            },
        }
    }

    /// Back `size` bytes at `base` that no region covers yet: a peripheral
    /// window mapped at attach (mram_window.zig, adc_tsn_cal.zig).
    pub fn map(self: Guest, base: u32, size: u32) MapError!void {
        switch (self) {
            .engine => |core| core.map(base, size) catch return MapError.Mapped,
            .store => |memory| try memory.map(base, size),
        }
    }

    pub fn readWord(self: Guest, address: u32) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }

    pub fn writeWord(self: Guest, address: u32, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.write(address, &bytes);
    }
};
