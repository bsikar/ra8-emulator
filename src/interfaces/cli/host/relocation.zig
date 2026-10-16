//! Application injection and the native peer's internal command entry.
const std = @import("std");
const history = @import("ra8_host").history;

pub fn peer(init: std.process.Init) !u8 {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 2 or !std.mem.eql(u8, argv[1], "--internal-host-move")) return error.BadArguments;
    return history.move.peer.peer(init.arena.allocator(), init.io);
}

pub fn capability(io: std.Io, executable: []const u8) !history.move.provider.Provider {
    return .{ .executable = executable, .sha256 = try history.move.provider.digest(io, executable) };
}

/// executable and its Provider must outlive Base and every Session.
pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, role: history.base.Role, executable: []const u8) !history.base.Base {
    return history.base.Base.openConfigured(allocator, io, path, role, .{ .native_provider = try capability(io, executable) });
}
