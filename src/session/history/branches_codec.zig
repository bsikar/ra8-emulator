//! The branches.bin wire codec: serialization, deserialization, and CRC-32C
//! verification for the persistent branch graph metadata.
//!
//! Binary wire format:
//!   Header (32 bytes):
//!     magic: [8]u8 = "RA8BRAN1"
//!     version: u32 = 1
//!     branch_count: u32
//!     active_branch: u32
//!     next_branch_id: u32
//!     reserved: [8]u8 = 0
//!   Records (branch_count * 56 bytes):
//!     id: u32
//!     parent: u32
//!     reason: u8
//!     flags: u8 (bit 0 = is_live, bit 1 = kept, bit 2 = pruned_tail)
//!     pins: u16
//!     created_ns: u64
//!     fork_at: Position (18 bytes)
//!     recorded_end: Position (18 bytes)
//!   Trailer (8 bytes):
//!     crc32c: u32 (over header and all records)
//!     end_magic: [4]u8 = "EDBR"
const std = @import("std");
const branch_mod = @import("branch.zig");
const history_position = @import("position.zig");
const history_record = @import("record.zig");
const history_format = @import("format.zig");

const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const header_magic = "RA8BRAN1";
pub const trailer_magic = "EDBR";
pub const version: u32 = 1;

pub const header_len: usize = 32;
pub const record_len: usize = 56;
pub const trailer_len: usize = 8;

pub const Error = error{
    Truncated,
    BadMagic,
    BadVersion,
    BadLength,
    BadCrc,
    BadValue,
    OutOfMemory,
};

pub fn encodedSize(branch_count: usize) usize {
    return header_len + branch_count * record_len + trailer_len;
}

fn writePositionBytes(buf: *[18]u8, pos: history_position.Position) void {
    std.mem.writeInt(u32, buf[0..4], pos.branch, .little);
    std.mem.writeInt(u64, buf[4..12], pos.r, .little);
    buf[12] = @backingInt(pos.phase);
    std.mem.writeInt(u32, buf[13..17], pos.o, .little);
    buf[17] = @backingInt(pos.gap);
}

pub fn encode(graph: *const branch_mod.BranchGraph, writer: anytype) !void {
    const count: u32 = @intCast(graph.nodes.count());
    var crc = Crc32c.init();

    var header_buf: [header_len]u8 = undefined;
    @memcpy(header_buf[0..8], header_magic);
    std.mem.writeInt(u32, header_buf[8..12], version, .little);
    std.mem.writeInt(u32, header_buf[12..16], count, .little);
    std.mem.writeInt(u32, header_buf[16..20], graph.active_branch, .little);
    std.mem.writeInt(u32, header_buf[20..24], graph.next_branch_id, .little);
    @memset(header_buf[24..32], 0);

    try writer.writeAll(&header_buf);
    crc.update(&header_buf);

    var it = graph.nodes.valueIterator();
    while (it.next()) |node| {
        var rec_buf: [record_len]u8 = undefined;
        std.mem.writeInt(u32, rec_buf[0..4], node.id, .little);
        std.mem.writeInt(u32, rec_buf[4..8], node.parent, .little);
        rec_buf[8] = @backingInt(node.reason);
        var flags: u8 = 0;
        if (node.is_live) flags |= 1;
        if (node.kept) flags |= 2;
        if (node.pruned_tail) flags |= 4;
        rec_buf[9] = flags;
        std.mem.writeInt(u16, rec_buf[10..12], node.pins, .little);
        std.mem.writeInt(u64, rec_buf[12..20], node.created_ns, .little);

        writePositionBytes(rec_buf[20..38], node.fork_at);
        writePositionBytes(rec_buf[38..56], node.recorded_end);

        try writer.writeAll(&rec_buf);
        crc.update(&rec_buf);
    }

    var trailer_buf: [trailer_len]u8 = undefined;
    std.mem.writeInt(u32, trailer_buf[0..4], crc.final(), .little);
    @memcpy(trailer_buf[4..8], trailer_magic);

    try writer.writeAll(&trailer_buf);
}

pub fn encodeAlloc(graph: *const branch_mod.BranchGraph, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try encode(graph, &buf.writer);
    return try allocator.dupe(u8, buf.written());
}

pub fn validate(bytes: []const u8) bool {
    if (bytes.len < header_len + trailer_len) return false;
    if (!std.mem.eql(u8, bytes[0..8], header_magic)) return false;
    const ver = std.mem.readInt(u32, bytes[8..12], .little);
    if (ver != version) return false;
    const count = std.mem.readInt(u32, bytes[12..16], .little);
    const expected = header_len + count * record_len + trailer_len;
    if (bytes.len != expected) return false;
    if (!std.mem.eql(u8, bytes[bytes.len - 4 ..], trailer_magic)) return false;

    var crc = Crc32c.init();
    crc.update(bytes[0 .. bytes.len - trailer_len]);
    const stored_crc = std.mem.readInt(u32, bytes[bytes.len - 8 ..][0..4], .little);
    return crc.final() == stored_crc;
}

fn decodeRecord(rec: *const [record_len]u8) Error!branch_mod.BranchNode {
    const id = std.mem.readInt(u32, rec[0..4], .little);
    const parent = std.mem.readInt(u32, rec[4..8], .little);
    const reason_raw = rec[8];
    if (reason_raw > @backingInt(history_record.ForkReason.load)) {
        return Error.BadValue;
    }
    const reason: history_record.ForkReason = @fromBackingInt(@intCast(reason_raw));
    const flags = rec[9];
    const pins = std.mem.readInt(u16, rec[10..12], .little);
    const created_ns = std.mem.readInt(u64, rec[12..20], .little);

    var fork_at_pos: usize = 0;
    const fork_at = history_position.decode(rec[20..38], &fork_at_pos) catch return Error.BadValue;

    var end_pos: usize = 0;
    const recorded_end = history_position.decode(rec[38..56], &end_pos) catch return Error.BadValue;

    return .{
        .id = id,
        .parent = parent,
        .fork_at = fork_at,
        .reason = reason,
        .created_ns = created_ns,
        .recorded_end = recorded_end,
        .pins = pins,
        .is_live = (flags & 1) != 0,
        .kept = (flags & 2) != 0,
        .pruned_tail = (flags & 4) != 0,
    };
}

fn validateHierarchy(graph: *const branch_mod.BranchGraph, count: usize) Error!void {
    const root_node = graph.nodes.get(branch_mod.root_branch_id) orelse return Error.BadValue;
    if (root_node.parent != branch_mod.root_branch_id) return Error.BadValue;

    var it_check = graph.nodes.valueIterator();
    while (it_check.next()) |node| {
        if (node.id == branch_mod.root_branch_id) continue;
        if (!graph.nodes.contains(node.parent)) return Error.BadValue;
        if (node.parent == node.id) return Error.BadValue;

        var curr = node.parent;
        var steps: usize = 0;
        while (curr != branch_mod.root_branch_id) : (steps += 1) {
            if (curr == node.id or steps > count) return Error.BadValue;
            const p_node = graph.nodes.get(curr) orelse return Error.BadValue;
            curr = p_node.parent;
        }
    }
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!branch_mod.BranchGraph {
    if (bytes.len < header_len + trailer_len) return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], header_magic)) return Error.BadMagic;
    const ver = std.mem.readInt(u32, bytes[8..12], .little);
    if (ver != version) return Error.BadVersion;
    const count = std.mem.readInt(u32, bytes[12..16], .little);
    const active_branch = std.mem.readInt(u32, bytes[16..20], .little);
    const next_branch_id = std.mem.readInt(u32, bytes[20..24], .little);

    const expected = header_len + count * record_len + trailer_len;
    if (bytes.len < expected) return Error.Truncated;
    if (bytes.len != expected) return Error.BadLength;

    if (!std.mem.eql(u8, bytes[bytes.len - 4 ..], trailer_magic)) return Error.BadMagic;
    var crc = Crc32c.init();
    crc.update(bytes[0 .. bytes.len - trailer_len]);
    const stored_crc = std.mem.readInt(u32, bytes[bytes.len - 8 ..][0..4], .little);
    if (crc.final() != stored_crc) return Error.BadCrc;

    var graph = branch_mod.BranchGraph{
        .allocator = allocator,
        .nodes = std.AutoHashMap(branch_mod.BranchId, branch_mod.BranchNode).init(allocator),
        .active_branch = active_branch,
        .next_branch_id = next_branch_id,
    };
    errdefer graph.deinit();

    var offset: usize = header_len;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const node = try decodeRecord(bytes[offset..][0..record_len]);
        const slot = try graph.nodes.getOrPut(node.id);
        if (slot.found_existing) return Error.BadValue;
        slot.value_ptr.* = node;
        offset += record_len;
    }

    try validateHierarchy(&graph, count);
    // The CRC guards torn bytes only: a graph whose active branch is
    // missing or whose next id is already taken is refused here.
    graph.validate() catch return Error.BadValue;
    return graph;
}

pub fn rebuildFromLogFrames(
    allocator: std.mem.Allocator,
    frames: []const history_format.Frame,
) !branch_mod.BranchGraph {
    var graph = try branch_mod.BranchGraph.init(allocator);
    errdefer graph.deinit();

    for (frames) |frame| {
        const raw_kind = frame.kind & ~history_record.mandatory_bit;
        if (raw_kind == @backingInt(history_record.Kind.branch)) {
            const branch_rec = history_record.decodeBranch(frame.payload) catch continue;
            const b = branch_rec.branch;
            if (graph.nodes.getPtr(b.id)) |existing| {
                existing.parent = b.parent;
                existing.fork_at = b.fork_at;
                existing.reason = b.reason;
            } else {
                try graph.insertNode(.{
                    .id = b.id,
                    .parent = b.parent,
                    .fork_at = b.fork_at,
                    .reason = b.reason,
                    .created_ns = 0,
                    .recorded_end = b.fork_at,
                });
            }
        }
    }
    // Branch records name their own parents; a log whose records do not
    // form a tree (a parent never recorded) is not a graph to adopt.
    graph.validate() catch return Error.BadValue;
    return graph;
}
