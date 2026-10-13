//! Borrowed authorities held by a lifecycle caller throughout relocation.
const std = @import("std");
const Base = @import("../base.zig").Base;
const file = @import("file.zig");
const layout = @import("../layout.zig");
pub const Context = struct {
    source: *const Base,
    target: *const Base,
    authorities: []const std.Io.File,

    pub fn validate(self: Context, from: []const u8) !void {
        try self.source.owns(from);
        try self.target.checkMarked();
        try self.authorized(from);
        try owned(self.source, from);
    }

    pub fn authorized(self: Context, from: []const u8) !void {
        if (self.authorities.len < 2 or self.authorities.len > 4) return error.MissingAuthority;
        for (self.authorities) |held| try @import("../metadata.zig").ordinary(try held.stat(self.source.io));
        try self.named(self.source, layout.root.gate, false, from);
        try self.named(self.target, layout.root.gate, false, from);
        var buffer: @import("../name.zig").Buffer = undefined;
        const lease = @import("../name.zig").lease(&buffer, @import("../name.zig").classify(from).id);
        try self.named(self.source, lease, true, from);
        if (!std.mem.eql(u8, self.source.path, self.target.path)) try self.named(self.target, lease, true, from);
    }

    fn named(self: Context, base: *const Base, leaf: []const u8, lease: bool, from: []const u8) !void {
        const opened = try @import("../metadata.zig").open(base.io, base.dir, leaf, .read_only);
        defer opened.close(base.io);
        const expected = try file.opened(opened);
        for (self.authorities) |held| {
            if (!expected.same(try file.opened(held))) continue;
            if (!try held.tryLock(base.io, .exclusive)) return error.Locked;
            if (lease) try @import("../lease.zig").validate(base.io, base.dir, held, @import("../name.zig").classify(from).id);
            return;
        }
        return error.MissingAuthority;
    }

    pub fn owned(base: *const Base, entry: []const u8) !void {
        var dir = try base.dir.openDir(base.io, entry, .{ .follow_symlinks = false });
        defer dir.close(base.io);
        const owner = @import("../owner.zig");
        const machine = @import("../machine.zig");
        var bytes: [owner.max_bytes]u8 = undefined;
        const record = try owner.read(base.io, dir, &bytes);
        var host: [machine.limits.host]u8 = undefined;
        const local = machine.hostName(&host);
        if (std.mem.eql(u8, local, machine.unknown) or !std.mem.eql(u8, local, record.host)) return error.OtherHost;
    }

    pub fn recheck(self: Context, from: []const u8, source_id: file.State, source_root: file.State, target_root: file.State) !void {
        try self.authorized(from);
        const io = self.source.io;
        var source = try std.Io.Dir.cwd().openDir(io, self.source.path, .{ .follow_symlinks = false });
        defer source.close(io);
        var target = try std.Io.Dir.cwd().openDir(io, self.target.path, .{ .follow_symlinks = false });
        defer target.close(io);
        if (!source_root.same(try file.here(source)) or !target_root.same(try file.here(target)) or !source_id.same(try file.state(source, from))) return error.IdentityConflict;
    }

    pub fn marker(root: *const Base) ![]const u8 {
        return switch (root.role) {
            .cache => layout.root.marker_text,
            .kept => layout.root.kept_marker_text,
            .runtime => error.WrongRole,
        };
    }
};
