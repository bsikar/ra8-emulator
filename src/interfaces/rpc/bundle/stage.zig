//! Private, leased import destination. Only this newly created session is removed on failure.
const std = @import("std");

const Bind = @import("../history_bind.zig").Bind;
const bundle = @import("ra8_snapshot").bundle;
const history = @import("ra8_host").history;

pub const Stage = struct {
    base: history.base.Base,
    session: history.session.Session,
    transferred: bool = false,

    pub fn init(self: *Stage, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        self.base = try history.base.Base.openConfigured(gpa, io, path, .cache, .{ .recover = false });
        errdefer self.base.close();
        self.session = try history.session.Session.create(&self.base, .{});
    }

    pub fn close(self: *Stage) !void {
        if (self.transferred) return;
        defer self.base.close();
        _ = try self.session.close(null, .move);
        self.transferred = true;
    }

    pub fn adopt(self: *Stage, gpa: std.mem.Allocator) !*Bind {
        const bind = try Bind.adopt(gpa, &self.base, &self.session);
        self.transferred = true;
        return bind;
    }

    pub fn copy(self: *Stage, reader: *bundle.reader.Reader, entry: bundle.reader.Entry) !void {
        const space: history.layout.Space = switch (entry.kind) {
            .root, .branches => .top,
            .log => .log,
            .object => .objects,
            .snapshot => return error.UnexpectedEntry,
        };
        const slash = std.mem.findLast(u8, entry.name, "/") orelse return error.BadEntry;
        const store = history.storage.Store.from(&self.session);
        const byte = try store.vtable.open(store.context, space, entry.name[slash + 1 ..], .create);
        defer byte.vtable.close(byte.context);
        const native = try history.storage.native(byte);
        var buffer: [65536]u8 = undefined;
        var output = native.writer(self.base.io, &buffer);
        try reader.copy(&output.interface);
        try output.interface.flush();
        try byte.vtable.sync(byte.context);
    }

    pub fn read(self: *Stage, gpa: std.mem.Allocator, space: history.layout.Space, leaf: []const u8, max: usize) ![]u8 {
        const store = history.storage.Store.from(&self.session);
        const byte = try store.vtable.open(store.context, space, leaf, .read);
        defer byte.vtable.close(byte.context);
        const size = try byte.vtable.length(byte.context);
        if (size > max) return error.TooLarge;
        const bytes = try gpa.alloc(u8, @intCast(size));
        errdefer gpa.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = try byte.vtable.read(byte.context, offset, bytes[offset..]);
            if (count == 0) return error.Truncated;
            offset += count;
        }
        return bytes;
    }
};
