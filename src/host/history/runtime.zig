//! Owned runtime namespace and stale-listener reclamation. Applications
//! supply a connect probe, so OS files remain below this host boundary.
const std = @import("std");
const base = @import("base.zig");
const name = @import("name.zig");

pub const State = enum { live, stale };
pub const Probe = struct {
    context: *anyopaque,
    connect: *const fn (*anyopaque, []const u8) anyerror!State,
};

pub const Directory = struct {
    root: base.Base,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, runtime_path: []const u8) !Directory {
        return .{ .root = try base.Base.open(allocator, io, runtime_path, .runtime) };
    }

    pub fn close(self: *Directory) void {
        self.root.close();
    }

    pub fn path(self: *const Directory, allocator: std.mem.Allocator, leaf: []const u8) ![]u8 {
        return self.root.pathOf(allocator, try safeLeaf(leaf));
    }

    /// Returns a gate the caller holds until binding/announcing completes.
    /// A successful connect or any probe failure leaves both names intact.
    /// Applications must use this gate for listener publication too.
    pub fn prepare(self: *const Directory, socket: []const u8, discovery: []const u8, probe: Probe) !base.Gate {
        _ = try safeLeaf(socket);
        _ = try safeLeaf(discovery);
        if (std.mem.eql(u8, socket, discovery)) return error.BadName;
        var gate = try self.root.gate(.exclusive);
        errdefer gate.release();
        const absolute = try self.path(self.root.allocator, socket);
        defer self.root.allocator.free(absolute);
        if (try probe.connect(probe.context, absolute) == .live) return error.AlreadyServing;
        if (try kind(self, socket)) |socket_kind| {
            if (socket_kind != .unix_domain_socket) return error.OutsideRoot;
        }
        if (try kind(self, discovery)) |discovery_kind| {
            if (discovery_kind != .file) return error.OutsideRoot;
        }
        try erase(self, socket);
        try erase(self, discovery);
        return gate;
    }
};

fn safeLeaf(leaf: []const u8) ![]const u8 {
    _ = try name.component(leaf);
    if (name.classify(leaf).kind == .reserved) return error.BadName;
    return leaf;
}

fn kind(directory: *const Directory, leaf: []const u8) !?std.Io.File.Kind {
    const stat = directory.root.dir.statFile(directory.root.io, leaf, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return stat.kind;
}

fn erase(directory: *const Directory, leaf: []const u8) !void {
    directory.root.dir.deleteFile(directory.root.io, leaf) catch |err| if (err != error.FileNotFound) return err;
}
