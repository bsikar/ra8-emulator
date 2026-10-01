//! The memory the Zig core fetches, loads and stores through.
//!
//! The core owns no memory. It reaches whatever the run hands it through this
//! one interface: the board's RAM and peripheral bus in a real run, a flat
//! array in a test. Unicorn keeps its own view of the same bytes, which is
//! what lets a lockstep run compare the two.
const std = @import("std");

pub const Error = error{Unmapped};

pub const Bus = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, address: u32, into: []u8) Error!void,
        write: *const fn (ctx: *anyopaque, address: u32, bytes: []const u8) Error!void,
    };

    pub fn read(self: Bus, address: u32, into: []u8) Error!void {
        return self.vtable.read(self.ctx, address, into);
    }

    pub fn write(self: Bus, address: u32, bytes: []const u8) Error!void {
        return self.vtable.write(self.ctx, address, bytes);
    }

    pub fn readHalf(self: Bus, address: u32) Error!u16 {
        var bytes: [2]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u16, &bytes, .little);
    }

    pub fn readWord(self: Bus, address: u32) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }
};
