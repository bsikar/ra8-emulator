//! The late-marker cache's host side: the session library names the shape
//! (`late_marker.Storage`) and never opens a file, and this adapter fills
//! it from the history session's index space, next to the log and the
//! objects the bind already puts there.
const std = @import("std");
const history = @import("ra8_host").history;
const late_marker = @import("ra8_session").history_late_marker;

/// The index-space store one history session's cache files live in.
pub const MarkerStore = struct {
    gpa: std.mem.Allocator,
    store: history.storage.Store,

    pub fn storage(self: *MarkerStore) late_marker.Storage {
        return .{ .context = self, .vtable = &storage_vtable };
    }
};

const storage_vtable = late_marker.Storage.Vtable{
    .open = &openFile,
    .create = &createFile,
};

/// One open cache file: the host byte file behind the session shape.
const MarkerFile = struct {
    owner: *MarkerStore,
    bytes: history.storage.ByteFile,

    const vtable = late_marker.File.Vtable{ .read = &read, .write = &write, .close = &close };

    fn read(context: *anyopaque, offset: u64, buffer: []u8) anyerror!usize {
        const self: *MarkerFile = @ptrCast(@alignCast(context));
        return self.bytes.vtable.read(self.bytes.context, offset, buffer);
    }

    fn write(context: *anyopaque, offset: u64, bytes: []const u8) anyerror!void {
        const self: *MarkerFile = @ptrCast(@alignCast(context));
        try self.bytes.vtable.write(self.bytes.context, offset, bytes);
        try self.bytes.vtable.sync(self.bytes.context);
    }

    fn close(context: *anyopaque) void {
        const self: *MarkerFile = @ptrCast(@alignCast(context));
        self.bytes.vtable.close(self.bytes.context);
        self.owner.gpa.destroy(self);
    }
};

fn wrap(owner: *MarkerStore, bytes: history.storage.ByteFile) !late_marker.File {
    const file = owner.gpa.create(MarkerFile) catch |err| {
        bytes.vtable.close(bytes.context);
        return err;
    };
    file.* = .{ .owner = owner, .bytes = bytes };
    return .{ .context = file, .vtable = &MarkerFile.vtable };
}

fn openFile(context: *anyopaque, name: []const u8) anyerror!late_marker.File {
    const owner: *MarkerStore = @ptrCast(@alignCast(context));
    return wrap(owner, try owner.store.vtable.open(owner.store.context, .index, name, .read));
}

/// A fresh file, or the existing one emptied: the cache is rewritten whole.
fn createFile(context: *anyopaque, name: []const u8) anyerror!late_marker.File {
    const owner: *MarkerStore = @ptrCast(@alignCast(context));
    const store = owner.store;
    const bytes = store.vtable.open(store.context, .index, name, .create) catch |err| switch (err) {
        error.PathAlreadyExists => blk: {
            const held = try store.vtable.open(store.context, .index, name, .update);
            errdefer held.vtable.close(held.context);
            try held.vtable.truncate(held.context, 0);
            break :blk held;
        },
        else => return err,
    };
    return wrap(owner, bytes);
}
