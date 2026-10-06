//! A handle on the Zig core's store with the bus-master identity used by the
//! shared external-memory fabric.
const std = @import("std");
const code_lines = @import("../code_lines.zig");
const external = @import("../../external_memory.zig");
const Store = @import("store.zig").Store;

pub const Error = error{Unmapped};
pub const MapError = error{ Mapped, Full, OutOfMemory };

pub const Guest = struct {
    store: *Store,
    master: external.Master = .none,

    pub fn asMaster(self: Guest, master: external.Master) Guest {
        return .{ .store = self.store, .master = master };
    }

    pub fn read(self: Guest, address: u32, into: []u8) Error!void {
        self.store.read(self.master, address, into) catch return Error.Unmapped;
    }

    pub fn write(self: Guest, address: u32, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        self.store.write(self.master, address, bytes) catch return Error.Unmapped;
        code_lines.notify(address, bytes.len);
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
