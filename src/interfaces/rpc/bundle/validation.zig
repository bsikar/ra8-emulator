//! Content admission for a private recording, before it can replace a live session.
const std = @import("std");

const history = @import("ra8_host").history;
const objects = @import("../object_read.zig");
const session = @import("ra8_session");
const setup = @import("../served_setup.zig");
const snapshot = @import("ra8_snapshot");
const Stage = @import("stage.zig").Stage;

pub const max_file = 256 * 1024 * 1024;

pub fn snapshotSections(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var reader = try snapshot.file.Reader.open(bytes);
    var seen = std.AutoHashMap(u32, void).init(gpa);
    defer seen.deinit();
    while (try reader.next()) |section| {
        if (seen.count() >= 1024) return error.TooManySections;
        const item = try seen.getOrPut(@backingInt(section.kind));
        if (item.found_existing) return error.DuplicateSection;
    }
}

pub fn branches(gpa: std.mem.Allocator, stage: *Stage) !session.history_branch.BranchGraph {
    const bytes = try stage.read(gpa, .top, "branches.bin", 8 * 1024 * 1024);
    defer gpa.free(bytes);
    if (bytes.len < session.history_branches_codec.header_len) return error.Truncated;
    if (std.mem.readInt(u32, bytes[12..16], .little) > 4096) return error.TooManyBranches;
    return session.history_branches_codec.decode(gpa, bytes);
}

pub const Logs = struct {
    gpa: std.mem.Allocator,
    store: history.storage.Store,
    graph: *const session.history_branch.BranchGraph,
    root: []const u8,
    candidate: ?*setup.Served = null,
    checkpoints: usize = 0,
    next_segment: u32 = 0,

    pub fn check(self: *Logs) !void {
        try self.store.vtable.list(self.store.context, .log, .{ .context = self, .visit = visit });
    }

    fn visit(context: *anyopaque, leaf: []const u8, size: u64) anyerror!void {
        const self: *Logs = @ptrCast(@alignCast(context));
        const segment = try segmentOf(leaf);
        if (self.graph.get(segment.branch) == null) return error.NoSuchBranch;
        if (segment.branch == self.graph.active_branch) {
            if (segment.index == std.math.maxInt(u32)) return error.TooManySegments;
            self.next_segment = @max(self.next_segment, segment.index + 1);
        }
        if (size > 64 * 1024 * 1024) return error.TooLarge;
        const byte = try self.store.vtable.open(self.store.context, .log, leaf, .read);
        defer byte.vtable.close(byte.context);
        const file = try history.storage.native(byte);
        var buffer: [65536]u8 = undefined;
        var reader = file.readerStreaming(self.storeIo(), &buffer);
        const bytes = try reader.interface.allocRemaining(self.gpa, .limited(@intCast(size)));
        defer self.gpa.free(bytes);
        if (bytes.len != size) return error.Truncated;
        const walked = try session.history_replay.replay(bytes, self, record);
        if (walked.torn) return error.TruncatedLog;
    }

    fn storeIo(self: *Logs) std.Io {
        const held: *history.session.Session = @ptrCast(@alignCast(self.store.context));
        return held.base.io;
    }

    fn record(self: *Logs, entry: session.history_replay.Entry) anyerror!void {
        const at = switch (entry) {
            .root => null,
            inline else => |value| value.header.position,
        };
        if (at) |position| {
            const node = self.graph.get(position.branch) orelse return error.NoSuchBranch;
            if (try self.graph.compareOnLine(position.branch, position, node.recorded_end) == .gt) {
                return error.PositionOutsideRecording;
            }
        }
        switch (entry) {
            .root => |bytes| {
                if (!std.mem.eql(u8, self.root, bytes)) return error.RootMismatch;
            },
            .checkpoint => |checkpoint| {
                self.checkpoints += 1;
                if (self.checkpoints > 4096) return error.TooManyCheckpoints;
                if (self.candidate) |candidate| try checkpointCheck(self.gpa, candidate, checkpoint);
            },
            .checkpoint_picture => |picture| {
                if (self.candidate) |candidate| {
                    const bytes = try recordedContent(self.gpa, candidate, picture.checkpoint.object);
                    self.gpa.free(bytes);
                }
            },
            else => {},
        }
    }
};

const Segment = struct { branch: u32, index: u32 };

fn segmentOf(leaf: []const u8) !Segment {
    if (std.mem.eql(u8, leaf, "events-0")) return .{ .branch = 0, .index = 0 };
    if (!std.mem.startsWith(u8, leaf, "events-")) return error.BadLogName;
    var parts = std.mem.splitScalar(u8, leaf[7..], '-');
    const branch = std.fmt.parseInt(u32, parts.next() orelse return error.BadLogName, 10) catch return error.BadLogName;
    const index = std.fmt.parseInt(u32, parts.next() orelse return error.BadLogName, 10) catch return error.BadLogName;
    if (parts.next() != null) return error.BadLogName;
    return .{ .branch = branch, .index = index };
}

fn readObject(gpa: std.mem.Allocator, candidate: *setup.Served, name: []const u8) ![]u8 {
    const bind = candidate.history.?;
    const store = history.storage.Store.from(&bind.session);
    return objects.readLimited(store, gpa, name, max_file) catch |err| switch (err) {
        error.FileNotFound => (try bind.packs.get(
            gpa,
            try session.history_object_id.ObjectId.fromHex(name),
        )) orelse error.ObjectMissing,
        else => return err,
    };
}

fn checkpointCheck(
    gpa: std.mem.Allocator,
    candidate: *setup.Served,
    value: session.history_record.CheckpointRecord,
) !void {
    const id: session.history_object_id.ObjectId = .{ .bytes = value.checkpoint.object };
    const bytes = try recordedContent(gpa, candidate, id.bytes);
    defer gpa.free(bytes);
    try snapshotSections(gpa, bytes);
    try candidate.owner.state.files.readFrom(bytes);
    const grid = candidate.owner.session().grid orelse return error.MissingGrid;
    if (!std.meta.eql(grid.at, value.header.position)) return error.CheckpointPositionMismatch;
    // Derived sidecars are absent on some checkpoints; supplied sidecars must be sound.
    const manifest_name = session.history_manifest.objectName(id.bytes);
    if (try optionalObject(gpa, candidate, &manifest_name)) |manifest_bytes| {
        defer gpa.free(manifest_bytes);
        // Reuse the immutable-store admission checks before allocating decoded tables.
        try session.history_object_reuse.validate(gpa, .manifest, manifest_bytes, manifest_bytes);
        var decoded = try session.history_manifest.decode(gpa, manifest_bytes);
        defer decoded.deinit(gpa);
        for (decoded.pages) |page| {
            const data = try content(gpa, candidate, page.object);
            gpa.free(data);
        }
        for (decoded.blobs) |blob| {
            const data = try content(gpa, candidate, blob.object);
            gpa.free(data);
        }
        if (decoded.picture) |picture| {
            const data = try content(gpa, candidate, picture);
            gpa.free(data);
        }
    }
    const touched_name = session.history_touched_pages.objectName(id.bytes);
    if (try optionalObject(gpa, candidate, &touched_name)) |touched_bytes| {
        defer gpa.free(touched_bytes);
        try session.history_object_reuse.validate(gpa, .touched, touched_bytes, touched_bytes);
        var touched = try session.history_touched_pages.Touched.decodeSlice(gpa, touched_bytes);
        defer touched.deinit();
    }
}

fn optionalObject(gpa: std.mem.Allocator, candidate: *setup.Served, name: []const u8) !?[]u8 {
    return readObject(gpa, candidate, name) catch |err| switch (err) {
        error.ObjectMissing, error.FileNotFound => null,
        else => return err,
    };
}

fn content(gpa: std.mem.Allocator, candidate: *setup.Served, id: session.history_object_id.ObjectId) ![]u8 {
    var name: [32]u8 = undefined;
    id.formatHex(&name);
    const bytes = try readObject(gpa, candidate, &name);
    errdefer gpa.free(bytes);
    if (!id.eql(session.history_object_id.ObjectId.compute(bytes))) return error.ObjectIdentityMismatch;
    return bytes;
}

fn recordedContent(gpa: std.mem.Allocator, candidate: *setup.Served, identity: [16]u8) ![]u8 {
    const name = std.fmt.bytesToHex(identity, .lower);
    const bytes = try readObject(gpa, candidate, &name);
    errdefer gpa.free(bytes);
    // Log checkpoint/picture IDs use SHA-256/128; packed page/blob IDs use BLAKE3/128.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &identity, digest[0..16])) return error.ObjectIdentityMismatch;
    return bytes;
}
