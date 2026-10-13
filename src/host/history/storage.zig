//! File-free callback shape for injection at the application boundary.
//! The host adapter owns OS handles. Callers close every ByteFile before
//! closing Session, and keep Session/Base addresses stable while using it.
const std = @import("std");
const layout = @import("layout.zig");
const paths = @import("paths.zig");
const move = @import("move/root.zig");
const rename_file = @import("rename.zig");
const scratch = @import("scratch.zig");
const Session = @import("session.zig").Session;

pub const Mode = enum { read, update, create };
pub const ByteFile = struct {
    context: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        read: *const fn (*anyopaque, u64, []u8) anyerror!usize,
        write: *const fn (*anyopaque, u64, []const u8) anyerror!void,
        length: *const fn (*anyopaque) anyerror!u64,
        truncate: *const fn (*anyopaque, u64) anyerror!void,
        sync: *const fn (*anyopaque) anyerror!void,
        close: *const fn (*anyopaque) void,
    };
};

pub const Visitor = struct {
    context: *anyopaque,
    visit: *const fn (*anyopaque, []const u8, u64) anyerror!void,
};

pub const Store = struct {
    context: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        open: *const fn (*anyopaque, layout.Space, []const u8, Mode) anyerror!ByteFile,
        remove: *const fn (*anyopaque, layout.Space, []const u8) anyerror!void,
        rename: *const fn (*anyopaque, layout.Space, []const u8, []const u8) anyerror!void,
        list: *const fn (*anyopaque, layout.Space, Visitor) anyerror!void,
    };

    pub fn from(session: *Session) Store {
        return .{ .context = session, .vtable = &adapter };
    }
};

const adapter: Store.Vtable = .{ .open = open, .remove = remove, .rename = rename, .list = list };

fn sessionOf(context: *anyopaque) *Session {
    return @ptrCast(@alignCast(context));
}

fn open(context: *anyopaque, space: layout.Space, text: []const u8, mode: Mode) !ByteFile {
    const session = sessionOf(context);
    const io = session.base.io;
    _ = try paths.leaf(space, text);
    var dir = try paths.area(session, space);
    defer dir.close(io);
    const file = if (space == .frames or space == .scratch) blk: {
        if (mode != .create) return error.EphemeralOnly;
        break :blk try scratch.open(session, if (space == .frames) .frames else .scratch, text);
    } else switch (mode) {
        .create => try dir.createFile(io, text, .{ .read = true, .exclusive = true, .resolve_beneath = true }),
        .read, .update => blk: {
            try paths.regular(io, dir, text);
            break :blk try dir.openFile(io, text, .{ .mode = if (mode == .read) .read_only else .read_write, .follow_symlinks = false, .resolve_beneath = true });
        },
    };
    errdefer file.close(io);
    const owned = try session.base.allocator.create(OwnedFile);
    owned.* = .{ .allocator = session.base.allocator, .io = io, .file = file };
    return .{ .context = owned, .vtable = &OwnedFile.vtable };
}

fn remove(context: *anyopaque, space: layout.Space, text: []const u8) !void {
    const session = sessionOf(context);
    _ = try paths.leaf(space, text);
    var dir = try paths.area(session, space);
    defer dir.close(session.base.io);
    try paths.regular(session.base.io, dir, text);
    try dir.deleteFile(session.base.io, text);
}

fn rename(context: *anyopaque, space: layout.Space, from: []const u8, to: []const u8) !void {
    const session = sessionOf(context);
    var gate = try session.base.gate(.exclusive);
    defer gate.release();
    try rename_file.settle(session.base.io, session.dir);
    _ = try paths.leaf(space, from);
    _ = try paths.leaf(space, to);
    var dir = try paths.area(session, space);
    defer dir.close(session.base.io);
    try paths.regular(session.base.io, dir, from);
    move.preserve(session.base.io, dir, from, dir, to) catch |err| switch (err) {
        error.OperationUnsupported => return rename_file.linkedProbed(session.base.io, session.dir, dir, space, from, to, session.move_probe),
        else => return err,
    };
}

fn list(context: *anyopaque, space: layout.Space, visitor: Visitor) !void {
    const session = sessionOf(context);
    var dir = try paths.area(session, space);
    defer dir.close(session.base.io);
    var entries = dir.iterate();
    while (try entries.next(session.base.io)) |entry| {
        _ = paths.leaf(space, entry.name) catch continue;
        const stat = try dir.statFile(session.base.io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind == .file) try visitor.visit(visitor.context, entry.name, stat.size);
    }
}

const OwnedFile = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,

    const vtable: ByteFile.Vtable = .{ .read = read, .write = write, .length = length, .truncate = truncate, .sync = sync, .close = close };

    fn cast(context: *anyopaque) *OwnedFile {
        return @ptrCast(@alignCast(context));
    }

    fn read(context: *anyopaque, offset: u64, buffer: []u8) !usize {
        const self = cast(context);
        return self.file.readPositionalAll(self.io, buffer, offset);
    }

    fn write(context: *anyopaque, offset: u64, buffer: []const u8) !void {
        const self = cast(context);
        try self.file.writePositionalAll(self.io, buffer, offset);
    }

    fn length(context: *anyopaque) !u64 {
        const self = cast(context);
        return (try self.file.stat(self.io)).size;
    }

    fn truncate(context: *anyopaque, size: u64) !void {
        const self = cast(context);
        try self.file.setLength(self.io, size);
    }

    fn sync(context: *anyopaque) !void {
        const self = cast(context);
        try self.file.sync(self.io);
    }

    fn close(context: *anyopaque) void {
        const self = cast(context);
        self.file.close(self.io);
        self.allocator.destroy(self);
    }
};
