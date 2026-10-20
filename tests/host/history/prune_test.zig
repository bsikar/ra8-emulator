//! Covers src/host/history/prune.zig: the orphan sweep drops the object
//! files the committed log does not name, reports what it reclaimed, and
//! never deletes past a segment it cannot read.
const std = @import("std");
const history = @import("ra8").host.history;
const session_refs = @import("ra8").session.history_refs;
const session_format = @import("ra8").session.history_format;
const io = std.testing.io;
const allocator = std.testing.allocator;

const digest = [16]u8{ 0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
const referenced_name = "deadbeef0102030405060708090a0b0c";
const orphan_name = "ffffffffffffffffffffffffffffffff";

const Fake = struct {
    log_dir: std.Io.Dir,
    objects_dir: std.Io.Dir,

    fn storeOf(self: *Fake) history.storage.Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn dirOf(self: *Fake, space: history.layout.Space) std.Io.Dir {
        return if (space == .log) self.log_dir else self.objects_dir;
    }

    const vtable: history.storage.Store.Vtable = .{ .open = open, .remove = remove, .rename = rename, .list = list };

    fn open(context: *anyopaque, space: history.layout.Space, name: []const u8, mode: history.storage.Mode) anyerror!history.storage.ByteFile {
        const self: *Fake = @ptrCast(@alignCast(context));
        const dir = self.dirOf(space);
        const file = switch (mode) {
            .create => try dir.createFile(io, name, .{ .read = true, .exclusive = true }),
            else => blk: {
                _ = try dir.statFile(io, name, .{ .follow_symlinks = false });
                break :blk try dir.openFile(io, name, .{ .mode = .read_only, .follow_symlinks = false });
            },
        };
        errdefer file.close(io);
        const owned = try allocator.create(Owned);
        owned.* = .{ .owner = self, .file = file };
        return .{ .context = owned, .vtable = &Owned.vtable };
    }

    fn remove(context: *anyopaque, space: history.layout.Space, name: []const u8) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        try self.dirOf(space).deleteFile(io, name);
    }

    fn rename(context: *anyopaque, space: history.layout.Space, from: []const u8, to: []const u8) anyerror!void {
        _ = context;
        _ = space;
        _ = from;
        _ = to;
        return error.Unsupported;
    }

    fn list(context: *anyopaque, space: history.layout.Space, visitor: history.storage.Visitor) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        const dir = self.dirOf(space);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
            if (stat.kind == .file) try visitor.visit(visitor.context, entry.name, stat.size);
        }
    }

    const Owned = struct {
        owner: *Fake,
        file: std.Io.File,

        const vtable: history.storage.ByteFile.Vtable = .{ .read = read, .write = write, .length = length, .truncate = truncate, .sync = sync, .close = close };

        fn read(context: *anyopaque, offset: u64, buffer: []u8) anyerror!usize {
            const self: *Owned = @ptrCast(@alignCast(context));
            return self.file.readPositionalAll(io, buffer, offset);
        }

        fn write(context: *anyopaque, offset: u64, buffer: []const u8) anyerror!void {
            const self: *Owned = @ptrCast(@alignCast(context));
            try self.file.writePositionalAll(io, buffer, offset);
        }

        fn length(context: *anyopaque) anyerror!u64 {
            const self: *Owned = @ptrCast(@alignCast(context));
            return (try self.file.stat(io)).size;
        }

        fn truncate(context: *anyopaque, size: u64) anyerror!void {
            _ = context;
            _ = size;
            return error.Unsupported;
        }

        fn sync(context: *anyopaque) anyerror!void {
            _ = context;
        }

        fn close(context: *anyopaque) void {
            const self: *Owned = @ptrCast(@alignCast(context));
            self.file.close(io);
            allocator.destroy(self);
        }
    };
};

const Bridge = struct {
    fn collect(store: history.storage.Store, alloc: std.mem.Allocator, names: *std.StringHashMap(void)) anyerror!void {
        var gather = Gather{ .allocator = alloc, .names = names };
        var segments = Segments{ .store = store, .gather = &gather };
        try store.vtable.list(store.context, .log, .{ .context = &segments, .visit = &Segments.visit });
        if (gather.failed) |err| return err;
    }

    const Gather = struct {
        allocator: std.mem.Allocator,
        names: *std.StringHashMap(void),
        failed: ?anyerror = null,

        fn add(self: *Gather, name: session_refs.Name) void {
            if (self.failed != null) return;
            const key = self.allocator.dupe(u8, &name) catch {
                self.failed = error.OutOfMemory;
                return;
            };
            const hit = self.names.getOrPut(key) catch {
                self.allocator.free(key);
                self.failed = error.OutOfMemory;
                return;
            };
            if (hit.found_existing) self.allocator.free(key);
        }
    };

    const Segments = struct {
        store: history.storage.Store,
        gather: *Gather,

        fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
            _ = size;
            const self: *Segments = @ptrCast(@alignCast(context));
            const file = try self.store.vtable.open(self.store.context, .log, name, .read);
            defer file.vtable.close(file.context);
            const length: usize = @intCast(try file.vtable.length(file.context));
            const bytes = try self.gather.allocator.alloc(u8, length);
            defer self.gather.allocator.free(bytes);
            var got: usize = 0;
            while (got < bytes.len) {
                const read = try file.vtable.read(file.context, got, bytes[got..]);
                if (read == 0) break;
                got += read;
            }
            session_refs.scanCheckpointObjects(bytes[0..got], self.gather, Gather.add) catch |err| {
                self.gather.failed = err;
            };
        }
    };
};

fn writeSegment(fake: *Fake, bytes: []const u8) !void {
    const st = fake.storeOf();
    const file = try st.vtable.open(st.context, .log, "events-0", .create);
    defer file.vtable.close(file.context);
    try file.vtable.write(file.context, 0, bytes);
}

fn putObject(fake: *Fake, name: []const u8, bytes: []const u8) !void {
    const st = fake.storeOf();
    const file = try st.vtable.open(st.context, .objects, name, .create);
    defer file.vtable.close(file.context);
    try file.vtable.write(file.context, 0, bytes);
}

test "the orphan sweep drops the objects the log does not name" {
    var log_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer log_tmp.cleanup();
    var objects_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer objects_tmp.cleanup();
    var fake = Fake{ .log_dir = log_tmp.dir, .objects_dir = objects_tmp.dir };

    var buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    var payload: [24]u8 = undefined;
    @memcpy(payload[0..4], "hdr!");
    std.mem.writeInt(u32, payload[4..8], 7, .little);
    @memcpy(payload[8..24], &digest);
    try session_format.encode(&stream, @backingInt(@import("ra8").session.history_record.Kind.checkpoint), &payload);
    try writeSegment(&fake, stream.buffered());
    try putObject(&fake, referenced_name, "object!");
    try putObject(&fake, orphan_name, "orphans");

    const report = try history.prune.orphans(fake.storeOf(), allocator, .{ .collect = &Bridge.collect });
    try std.testing.expectEqual(@as(usize, 1), report.orphans);
    try std.testing.expectEqual(@as(u64, 7), report.orphan_bytes);

    // The referenced object is still there; the orphan is not.
    const st = fake.storeOf();
    const kept = try st.vtable.open(st.context, .objects, referenced_name, .read);
    kept.vtable.close(kept.context);
    try std.testing.expectError(error.FileNotFound, st.vtable.open(st.context, .objects, orphan_name, .read));
}

test "a segment the walk cannot finish stops the sweep" {
    var log_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer log_tmp.cleanup();
    var objects_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer objects_tmp.cleanup();
    var fake = Fake{ .log_dir = log_tmp.dir, .objects_dir = objects_tmp.dir };

    // A frame that lies about its CRC (not its length): len 4, kind 1,
    // crc 0xdeadbeef, a four-byte payload. The length passes the bound, so
    // the walk reaches the CRC check and stops there.
    try writeSegment(&fake, "\x04\x00\x00\x00\x01\x00\xef\xbe\xad\xde\x00\x00\x00\x00");
    try putObject(&fake, orphan_name, "orphans");

    try std.testing.expectError(error.BadCrc, history.prune.orphans(fake.storeOf(), allocator, .{ .collect = &Bridge.collect }));
    // Nothing was deleted.
    const st = fake.storeOf();
    const still = try st.vtable.open(st.context, .objects, orphan_name, .read);
    still.vtable.close(still.context);
}
