//! Create or decode the destination reservation for a directory move.
const h = @import("../root.zig");
const proof = @import("receipt.zig");
const std = @import("std");

pub fn reserve(io: std.Io, parent: std.Io.Dir, leaf: []const u8) !bool {
    return if (parent.createDir(io, leaf, h.layout.directory_permissions)) |_| true else |err| switch (err) {
        error.PathAlreadyExists => false,
        else => return err,
    };
}

pub fn reservation(allocator: std.mem.Allocator, io: std.Io, target: std.Io.Dir) !std.json.Parsed(proof.Record) {
    return proof.read(allocator, io, target, proof.origin) catch |err| return if (err == error.FileNotFound)
        error.UnknownReservation
    else
        err;
}
