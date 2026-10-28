//! State diff RPC handler (Slice 23.5): compares the machine at two
//! checkpoints of the session's history, read from the manifests the
//! checkpoints keep beside their objects. A target is `cursor` (the newest
//! checkpoint at or behind the cursor), `latest` (the newest checkpoint of
//! the line), `chk:ID` (a checkpoint by its id) or a bare index into the
//! line's checkpoints, 0 the oldest. The reply carries each side's real
//! position, the registers and peripheral words that differ, and the pages
//! whose objects differ.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const diff_wire = @import("diff_wire.zig");
const ra8_session = @import("ra8_session");
const diff_engine = ra8_session.history_diff_engine;
const manifest_mod = ra8_session.history_manifest;
const object_id = ra8_session.history_object_id;
const seek_engine = ra8_session.history_seek_engine;
const transport_mod = ra8_session.transport;

pub const DiffOutcome = rpc.Outcome(diff_wire.DiffWire);

/// The most page entries one reply carries.
const max_pages: usize = 200;

fn refuse() DiffOutcome {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}

fn lessByRound(_: void, a: seek_engine.Checkpoint, b: seek_engine.Checkpoint) bool {
    return a.position.r < b.position.r;
}

/// The line's checkpoints, oldest first: the cursor's branch when it has
/// any, otherwise all of them. The caller frees the slice.
fn lineCheckpoints(gpa: std.mem.Allocator, facts: seek_engine.Facts, branch: u32) ![]seek_engine.Checkpoint {
    var list: std.ArrayList(seek_engine.Checkpoint) = .empty;
    errdefer list.deinit(gpa);
    for (facts.checkpoints) |c| if (c.position.branch == branch) try list.append(gpa, c);
    if (list.items.len == 0) try list.appendSlice(gpa, facts.checkpoints);
    std.mem.sort(seek_engine.Checkpoint, list.items, {}, lessByRound);
    return list.toOwnedSlice(gpa);
}

fn pick(line: []const seek_engine.Checkpoint, target: []const u8, cursor_r: u64) ?seek_engine.Checkpoint {
    if (line.len == 0) return null;
    const text = std.mem.trim(u8, target, " \t");
    if (std.mem.eql(u8, text, "latest")) return line[line.len - 1];
    if (text.len == 0 or std.mem.eql(u8, text, "cursor")) {
        var best = line[0];
        for (line) |c| if (c.position.r <= cursor_r) {
            best = c;
        };
        return best;
    }
    if (std.mem.startsWith(u8, text, "chk:")) {
        const id = std.fmt.parseInt(u32, text[4..], 10) catch return null;
        for (line) |c| if (c.id == id) return c;
        return null;
    }
    const index = std.fmt.parseInt(usize, text, 10) catch return null;
    return if (index < line.len) line[index] else null;
}

/// Reads objects for the engine's blob lookups and owns what it returned.
const Blobs = struct {
    gpa: std.mem.Allocator,
    bridge: transport_mod.Bridge,
    owned: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Blobs) void {
        for (self.owned.items) |bytes| self.gpa.free(bytes);
        self.owned.deinit(self.gpa);
    }

    fn get(context: *anyopaque, id: object_id.ObjectId) ?[]const u8 {
        const self: *Blobs = @ptrCast(@alignCast(context));
        var name: [object_id.ObjectId.hex_len]u8 = undefined;
        id.formatHex(&name);
        const bytes = self.read(&name) orelse return null;
        self.owned.append(self.gpa, bytes) catch {
            self.gpa.free(bytes);
            return null;
        };
        return bytes;
    }

    fn read(self: *Blobs, name: []const u8) ?[]u8 {
        const reader = self.bridge.readObject orelse return null;
        return reader(self.bridge.context, self.gpa, name) catch null;
    }

    fn manifest(self: *Blobs, cp: seek_engine.Checkpoint) ?manifest_mod.Manifest {
        const name = manifest_mod.objectName(cp.object);
        const bytes = self.read(&name) orelse return null;
        defer self.gpa.free(bytes);
        return manifest_mod.decode(self.gpa, bytes) catch null;
    }
};

pub fn diff(context: *handlers.Context, args: proto.DiffArgs) DiffOutcome {
    const gpa = context.gpa orelse return refuse();
    const plane = context.transport orelse return refuse();
    const bridge = plane.history orelse return refuse();
    var facts = bridge.facts(bridge.context) catch return refuse();
    const cursor = context.session.currentPosition();
    const line = lineCheckpoints(gpa, facts, cursor.branch) catch return refuse();
    defer gpa.free(line);
    facts.checkpoints = line;

    const cp_a = pick(line, args.a, cursor.r) orelse return refuse();
    const cp_b = pick(line, args.b, cursor.r) orelse return refuse();
    var blobs: Blobs = .{ .gpa = gpa, .bridge = bridge };
    defer blobs.deinit();
    var man_a = blobs.manifest(cp_a) orelse return refuse();
    defer man_a.deinit(gpa);
    var man_b = blobs.manifest(cp_b) orelse return refuse();
    defer man_b.deinit(gpa);

    var result = diff_engine.diffManifests(gpa, &man_a, &man_b, &Blobs.get, &blobs) catch return refuse();
    defer result.deinit(gpa);
    const frames: u16 = @intCast(@min(line.len, std.math.maxInt(u16)));
    return encode(context, frames, &result) catch refuse();
}

fn encode(context: *handlers.Context, frames: u16, result: *const diff_engine.DiffResult) !DiffOutcome {
    const gpa = context.gpa.?;
    var regs: std.ArrayList(diff_wire.RegItem) = .empty;
    defer regs.deinit(gpa);
    for (result.cpu0_regs) |r| try regs.append(gpa, .{ .core = 0, .name = r.name, .val_a = r.val_a, .val_b = r.val_b });
    for (result.cpu1_regs) |r| try regs.append(gpa, .{ .core = 1, .name = r.name, .val_a = r.val_a, .val_b = r.val_b });

    var pages: std.ArrayList(diff_wire.PageItem) = .empty;
    defer pages.deinit(gpa);
    for (result.pages[0..@min(result.pages.len, max_pages)]) |p| try pages.append(gpa, .{
        .space = @backingInt(p.space),
        .page_index = p.page_index,
        .address = p.address,
        .has_a = @intFromBool(p.obj_a != null),
        .obj_a = if (p.obj_a) |o| o.bytes else @splat(0),
        .has_b = @intFromBool(p.obj_b != null),
        .obj_b = if (p.obj_b) |o| o.bytes else @splat(0),
    });

    var periphs: std.ArrayList(diff_wire.PeriphItem) = .empty;
    defer periphs.deinit(gpa);
    for (result.periphs) |p| try periphs.append(gpa, .{ .unit = p.unit, .offset = p.offset, .old_val = p.old_val, .new_val = p.new_val, .changed_bytes = p.changed_bytes });

    var writer: std.Io.Writer = .fixed(context.scratch);
    const a: diff_wire.Side = .{ .branch = result.pos_a.branch, .r = result.pos_a.r };
    const b: diff_wire.Side = .{ .branch = result.pos_b.branch, .r = result.pos_b.r };
    try diff_wire.encodeSides(&writer, frames, a, b, regs.items, pages.items, periphs.items);
    return .{ .ok = .{ .bytes = writer.buffered() } };
}
