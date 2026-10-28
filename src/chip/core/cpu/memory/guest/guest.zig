//! A handle on the Zig core's store with the bus-initiator identity used by the
//! shared external-memory fabric.
const std = @import("std");
const Initiator = @import("../initiator.zig").Initiator;
const Store = @import("../store.zig").Store;
pub const bus = @import("bus.zig");

pub const Error = error{Unmapped};
pub const MapError = error{ Mapped, Full, OutOfMemory };
pub const ReadFn = *const fn (ctx: *anyopaque, address: u32, into: []u8) Error!void;

pub const Guest = struct {
    store: *Store,
    initiator: Initiator = .none,
    read_fn: ?ReadFn = null,
    read_ctx: ?*anyopaque = null,

    pub fn asInitiator(self: Guest, initiator: Initiator) Guest {
        return .{
            .store = self.store,
            .initiator = initiator,
            .read_fn = self.read_fn,
            .read_ctx = self.read_ctx,
        };
    }

    pub fn read(self: Guest, address: u32, into: []u8) Error!void {
        if (self.read_fn) |rf| return rf(self.read_ctx orelse return Error.Unmapped, address, into);
        self.store.read(self.initiator, address, into) catch return Error.Unmapped;
    }

    pub fn write(self: Guest, address: u32, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        self.store.write(self.initiator, address, bytes) catch return Error.Unmapped;
        self.store.fan().notify(address, bytes.len);
    }

    pub fn backed(self: Guest, address: u32, len: usize) bool {
        return self.store.backed(address, len);
    }

    pub fn map(self: Guest, base: u32, size: u32) MapError!void {
        try self.store.map(base, size);
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
