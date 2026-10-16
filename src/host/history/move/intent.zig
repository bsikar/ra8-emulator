//! Root-anchored native intent moves with its source, never with a lease.
const std = @import("std");
const h = @import("../root.zig");
const file = @import("file.zig");
const Context = @import("context.zig").Context;
const wire = @import("wire.zig");
const deadline = @import("deadline.zig");
pub const note = "native-moving";
pub const suffix = ".native-move";
const commit_flag = "\nCOMMIT\n";
const cancel_flag = "\nCANCEL\n";
pub const Record = struct {
    version: u32 = 2,
    /// Set by read from the anchor's synced journal, never from the note.
    committed: bool = false,
    cancelled: bool = false,
    nonce: h.name.Id,
    from_path: []const u8,
    to_path: []const u8,
    from: []const u8,
    to: []const u8,
    purpose: []const u8,
    source: file.State,
    source_root: file.State,
    target_root: file.State,
    anchor: file.State,
    marker: file.State,
};

pub fn leaf(buffer: *h.name.Buffer, id: []const u8) ![]const u8 {
    if (!h.name.isId(id)) return error.BadName;
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ id, suffix });
}

pub fn pending(io: std.Io, root: std.Io.Dir, id: []const u8) bool {
    var buffer: h.name.Buffer = undefined;
    return present(io, root, leaf(&buffer, id) catch return true);
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, anchor: bool) !std.json.Parsed(Record) {
    const held = try h.metadata.open(io, dir, path, .read_only);
    defer held.close(io);
    var bytes: [32768 + commit_flag.len + cancel_flag.len]u8 = undefined;
    const size = (try held.stat(io)).size;
    if (size == 0 or size > bytes.len) return error.BadReceipt;
    if (try held.readPositionalAll(io, bytes[0..@intCast(size)], 0) != size) return error.BadReceipt;
    const text = bytes[0..@intCast(size)];
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    if (end == 0 or end > 32768) return error.BadReceipt;
    var parsed = std.json.parseFromSlice(Record, allocator, text[0..end], .{ .allocate = .alloc_always }) catch |err| return if (err == error.OutOfMemory) err else error.BadReceipt;
    errdefer parsed.deinit();
    if ((parsed.value.version == 1 or parsed.value.version == 2) and !parsed.value.committed and !parsed.value.cancelled) {
        const tail = text[end..];
        if (tail.len != 0 and !anchor) return error.BadReceipt;
        if (std.mem.eql(u8, tail, commit_flag ++ cancel_flag)) {
            parsed.value.cancelled = true;
        } else if (std.mem.eql(u8, tail, commit_flag) or (tail.len == 0 and parsed.value.version == 1)) {
            // Old intents cannot prove that COMMIT never began.
            parsed.value.committed = true;
        } else if (tail.len != 0) return error.BadReceipt;
    } else return error.BadReceipt;
    const record = parsed.value;
    if (!h.name.isId(&record.nonce) or !std.fs.path.isAbsolute(record.from_path) or !std.fs.path.isAbsolute(record.to_path)) return error.BadReceipt;
    _ = try h.name.component(record.from);
    _ = try h.name.component(record.to);
    try names(record);
    if (!(if (anchor) record.anchor else record.marker).same(try file.opened(held))) return error.IdentityConflict;
    return parsed;
}

/// Both durable names as read through directories the reader already holds.
pub const BoundProof = struct {
    record: std.json.Parsed(Record),
    digest: wire.Proof,

    pub fn deinit(self: BoundProof) void {
        self.record.deinit();
    }
};

/// The anchor in `root` and the note in the pinned `source` must share one
/// JSON line; only the anchor may carry the COMMIT journal flag, and a
/// cancelled intent proves nothing. Both sides of a native move compute
/// this, and the digests bind every frame to these exact bytes.
pub fn boundProof(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, source: std.Io.Dir, from: []const u8) !BoundProof {
    var leaf_buffer: h.name.Buffer = undefined;
    const anchor_name = try leaf(&leaf_buffer, h.name.classify(from).id);
    var anchor_bytes: [32768 + commit_flag.len + cancel_flag.len]u8 = undefined;
    var note_bytes: [32768]u8 = undefined;
    const anchor_text = try h.metadata.read(io, root, anchor_name, &anchor_bytes);
    const note_text = try h.metadata.read(io, source, note, &note_bytes);
    const end = std.mem.indexOfScalar(u8, anchor_text, '\n') orelse anchor_text.len;
    if (end == 0 or !std.mem.eql(u8, anchor_text[0..end], note_text)) return error.IdentityConflict;
    const tail = anchor_text[end..];
    if (std.mem.eql(u8, tail, commit_flag ++ cancel_flag)) return error.NativeMoveCancelled;
    if (tail.len != 0 and !std.mem.eql(u8, tail, commit_flag)) return error.BadReceipt;
    var parsed = std.json.parseFromSlice(Record, allocator, note_text, .{ .allocate = .alloc_always }) catch |err| return if (err == error.OutOfMemory) err else error.BadReceipt;
    errdefer parsed.deinit();
    if ((parsed.value.version != 1 and parsed.value.version != 2) or parsed.value.committed or parsed.value.cancelled or !h.name.isId(&parsed.value.nonce) or !std.mem.eql(u8, parsed.value.from, from)) return error.BadReceipt;
    try names(parsed.value);
    return .{ .record = parsed, .digest = .{ .anchor = wire.digest(anchor_text), .note = wire.digest(note_text) } };
}

pub fn start(allocator: std.mem.Allocator, context: Context, from: []const u8, to: []const u8, purpose: []const u8) !std.json.Parsed(Record) {
    const base = context.source;
    const io = base.io;
    try checkNames(base.path, context.target.path, from, to, purpose);
    var buffer: h.name.Buffer = undefined;
    const id = h.name.classify(from).id;
    const anchor_name = try leaf(&buffer, id);
    if (present(io, base.dir, anchor_name)) return read(allocator, io, base.dir, anchor_name, true);
    var source = try base.dir.openDir(io, from, .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    const anchor = try base.dir.createFile(io, anchor_name, .{ .read = true, .exclusive = true });
    defer anchor.close(io);
    const marker = try source.createFile(io, note, .{ .read = true, .exclusive = true });
    defer marker.close(io);
    const record: Record = .{ .nonce = try h.lease.nonce(io, base.dir, id), .from_path = base.path, .to_path = context.target.path, .from = from, .to = to, .purpose = purpose, .source = try file.state(base.dir, from), .source_root = try file.here(base.dir), .target_root = try file.here(context.target.dir), .anchor = try file.opened(anchor), .marker = try file.opened(marker) };
    try names(record);
    const bytes = try std.json.Stringify.valueAlloc(allocator, record, .{});
    defer allocator.free(bytes);
    if (bytes.len > 32768) return error.BadReceipt;
    try marker.writeStreamingAll(io, bytes);
    try marker.sync(io);
    try anchor.writeStreamingAll(io, bytes);
    try anchor.sync(io);
    try file.syncDir(source);
    try file.syncDir(base.dir);
    return read(allocator, io, base.dir, anchor_name, true);
}

pub fn scope(context: Context, record: Record, from: []const u8, to: []const u8) !void {
    try names(record);
    const base = context.source;
    if (!std.mem.eql(u8, base.path, record.from_path) or !std.mem.eql(u8, context.target.path, record.to_path) or !std.mem.eql(u8, from, record.from) or !std.mem.eql(u8, to, record.to)) return error.IdentityConflict;
    if (!record.source_root.same(try file.here(base.dir)) or !record.target_root.same(try file.here(context.target.dir))) return error.IdentityConflict;
    const nonce = try h.lease.nonce(base.io, base.dir, h.name.classify(from).id);
    if (!std.mem.eql(u8, &nonce, &record.nonce)) return error.IdentityConflict;
}

/// Sync before even beginning a COMMIT write. A torn journal is unreadable
/// and retained, so it can never be mistaken for a known cancellation.
pub fn commit(context: Context, record: Record) !void {
    try journal(context, record, commit_flag, null);
}

/// Record a verified refusal before unlinking either intent marker. If the
/// caller crashes during cleanup, providerless recovery still cannot move.
pub fn cancel(context: Context, record: Record, settle: deadline.Deadline) !void {
    const io = context.source.io;
    try settle.live(io);
    try scope(context, record, record.from, record.to);
    try context.validate(record.from);
    try settle.live(io);
    try context.recheck(record.from, record.source, record.source_root, record.target_root);
    try settle.live(io);
    try journal(context, record, cancel_flag, settle);
    try settle.live(io);
    try cleanup(context, record, false, settle);
}

fn journal(context: Context, record: Record, flag: []const u8, settle: ?deadline.Deadline) !void {
    const base = context.source;
    try bound(settle, base.io);
    var buffer: h.name.Buffer = undefined;
    const path = try leaf(&buffer, h.name.classify(record.from).id);
    const current = try read(base.allocator, base.io, base.dir, path, true);
    defer current.deinit();
    try scope(context, current.value, record.from, record.to);
    if (!record.source.same(current.value.source) or !record.anchor.same(current.value.anchor) or !record.marker.same(current.value.marker) or !std.mem.eql(u8, &record.nonce, &current.value.nonce)) return error.IdentityConflict;
    if (std.mem.eql(u8, flag, commit_flag) and current.value.cancelled) return error.NativeMoveCancelled;
    if (std.mem.eql(u8, flag, commit_flag) == current.value.committed) return;
    try bound(settle, base.io);
    const held = try h.metadata.open(base.io, base.dir, path, .read_write);
    defer held.close(base.io);
    if (!record.anchor.same(try file.opened(held))) return error.IdentityConflict;
    const size = (try held.stat(base.io)).size;
    var bytes: [32768 + commit_flag.len + cancel_flag.len]u8 = undefined;
    if (size > bytes.len) return error.BadReceipt;
    if (try held.readPositionalAll(base.io, bytes[0..@intCast(size)], 0) != size) return error.BadReceipt;
    const has_flag = std.mem.indexOfScalar(u8, bytes[0..@intCast(size)], '\n') != null;
    const appended = if (current.value.version == 1 and !has_flag) commit_flag ++ cancel_flag else flag;
    try held.writePositionalAll(base.io, appended, size);
    try held.sync(base.io);
}

pub fn cleanup(context: Context, record: Record, moved: bool, settle: ?deadline.Deadline) !void {
    const io = context.source.io;
    const root = if (moved) context.target else context.source;
    const entry = if (moved) record.to else record.from;
    if (!record.source.same(try file.state(root.dir, entry))) return error.IdentityConflict;
    var buffer: h.name.Buffer = undefined;
    const anchor_name = try leaf(&buffer, h.name.classify(record.from).id);
    const anchor = try file.state(context.source.dir, anchor_name);
    if (!record.anchor.same(anchor) or anchor.links != 1) return error.IdentityConflict;
    var dir = try root.dir.openDir(io, entry, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    if (present(io, dir, note)) {
        const marker = try file.state(dir, note);
        if (!record.marker.same(marker) or marker.links != 1) return error.IdentityConflict;
        try bound(settle, io);
        try dir.deleteFile(io, note);
        try file.syncDir(dir);
    }
    try bound(settle, io);
    try context.source.dir.deleteFile(io, anchor_name);
    try file.syncDir(context.source.dir);
}

pub fn arrived(context: Context, record: Record) !bool {
    const source = file.state(context.source.dir, record.from) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const target = file.state(context.target.dir, record.to) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (source) |state| {
        if (!record.source.same(state)) return error.IdentityConflict;
        return false;
    }
    if (target) |state| if (record.source.same(state)) return true;
    return error.IdentityConflict;
}

/// A publication step may begin only inside its settle bound, so a stalled
/// journal can never carry a verdict past the admission that owns it.
fn bound(settle: ?deadline.Deadline, io: std.Io) !void {
    if (settle) |held| try held.live(io);
}

fn present(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    _ = dir.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn names(record: Record) !void {
    return checkNames(record.from_path, record.to_path, record.from, record.to, record.purpose);
}

fn checkNames(from_path: []const u8, to_path: []const u8, from_name: []const u8, to: []const u8, purpose: []const u8) !void {
    const from = h.name.classify(from_name);
    if (!h.name.isId(from.id)) return error.BadReceipt;
    const same_root = std.mem.eql(u8, from_path, to_path);
    if (std.mem.eql(u8, purpose, h.layout.moves.publish)) {
        if (!same_root or from.kind != .creating or !std.mem.eql(u8, to, from.id)) return error.BadReceipt;
    } else if (std.mem.eql(u8, purpose, h.layout.moves.trash)) {
        var buffer: h.name.Buffer = undefined;
        if (!same_root or (from.kind != .creating and from.kind != .session) or !std.mem.eql(u8, to, h.name.trash(&buffer, from.id))) return error.BadReceipt;
    } else if (std.mem.startsWith(u8, purpose, h.layout.moves.keep)) {
        const tail = purpose[h.layout.moves.keep.len..];
        if (from.kind != .session or !std.mem.eql(u8, to, from.id) or tail.len != to_path.len + 1 or !std.mem.startsWith(u8, tail, to_path) or tail[tail.len - 1] != '\n') return error.BadReceipt;
    } else return error.BadReceipt;
}
