//! Proven recovery under root gates and the never-moved OS lease. Unknown
//! reservations and unmarked directories are retained with diagnostics.
const std = @import("std");
const h = @import("root.zig");
const Base = h.base.Base;
const proof = h.move.receipt;
pub const Status = enum { completed, held, unmarked, unknown_reservation, conflict, other_host, failed };
pub const Report = struct { counts: [7]u64 = @splat(0) };
pub const Observer = struct { context: *anyopaque, report: *const fn (*anyopaque, []const u8, Status) void };

pub fn run(base: *const Base) anyerror!void {
    _ = try runReport(base, null);
}
pub fn runReport(base: *const Base, observer: ?Observer) anyerror!Report {
    if (base.role == .runtime) return error.WrongRole;
    var leases: std.ArrayList(h.name.Buffer) = .empty;
    defer leases.deinit(base.allocator);
    {
        var gate = try base.gate(.exclusive);
        defer gate.release();
        var entries = base.dir.iterate();
        while (try entries.next(base.io)) |entry| {
            if (h.name.classify(entry.name).kind != .lease) continue;
            var buffer: h.name.Buffer = @splat(0);
            @memcpy(buffer[0..entry.name.len], entry.name);
            try leases.append(base.allocator, buffer);
        }
    }
    var result: Report = .{};
    for (leases.items) |*buffer| {
        const id = h.name.classify(std.mem.sliceTo(buffer, 0)).id;
        const state = session(base, id) catch |err| switch (err) {
            error.UnknownReservation => Status.unknown_reservation,
            error.IdentityConflict, error.UnexpectedEntry, error.UnexpectedLinkCount => Status.conflict,
            error.OtherHost => Status.other_host,
            error.Unmarked, error.BadReceipt, error.BadMetadata, error.OutsideRoot => Status.unmarked,
            else => Status.failed,
        };
        result.counts[@backingInt(state)] += 1;
        if (observer) |hook| hook.report(hook.context, id, state);
    }
    return result;
}

pub fn session(base: *const Base, id: []const u8) anyerror!Status {
    var gate = try base.gate(.exclusive);
    var gate_open = true;
    defer if (gate_open) gate.release();
    const held = (try h.lock.take(base.io, base.dir, id)) orelse return .held;
    var held_open = true;
    defer if (held_open) held.close(base.io);
    var draft_buffer: h.name.Buffer = undefined;
    var bin_buffer: h.name.Buffer = undefined;
    const draft = h.name.creating(&draft_buffer, id);
    const bin = h.name.trash(&bin_buffer, id);
    var native_buffer: h.name.Buffer = undefined;
    if (present(base, try h.move.intent.leaf(&native_buffer, id))) {
        held.close(base.io);
        held_open = false;
        gate.release();
        gate_open = false;
        try h.move.recovery.root(base, id);
        return .completed;
    }
    var anchor_buffer: [h.name.limits.component]u8 = undefined;
    const anchor = try proof.anchorName(&anchor_buffer, id);
    if (present(base, anchor)) {
        const saved = try proof.read(base.allocator, base.io, base.dir, anchor);
        defer saved.deinit();
        try claim(base, id, saved.value);
        if (!std.mem.eql(u8, saved.value.to_path, base.path)) {
            const path = try base.allocator.dupe(u8, saved.value.to_path);
            defer base.allocator.free(path);
            held.close(base.io);
            held_open = false;
            gate.release();
            gate_open = false;
            return kept(base, id, path, true);
        }
        try h.move.tree.finishRecorded(base.allocator, base.io, base.dir, base.dir, saved.value);
        try removeAnchor(base, anchor, saved.value);
    }
    for ([_][]const u8{ draft, id }) |entry| {
        base.owns(entry) catch continue;
        if (!try h.move.tree.moving(base.io, base.dir, entry)) continue;
        var source = try base.dir.openDir(base.io, entry, .{ .follow_symlinks = false });
        const parsed = proof.read(base.allocator, base.io, source, h.layout.files.moving) catch |err| {
            source.close(base.io);
            return err;
        };
        source.close(base.io);
        defer parsed.deinit();
        try claim(base, id, parsed.value);
        if (std.mem.startsWith(u8, parsed.value.purpose, h.layout.moves.keep)) {
            const path = try base.allocator.dupe(u8, parsed.value.to_path);
            defer base.allocator.free(path);
            held.close(base.io);
            held_open = false;
            gate.release();
            gate_open = false;
            return kept(base, id, path, false);
        }
        const target = if (std.mem.eql(u8, parsed.value.purpose, h.layout.moves.publish)) id else if (std.mem.eql(u8, parsed.value.purpose, h.layout.moves.trash)) bin else return error.BadReceipt;
        if (!try proof.localOwner(base.allocator, base.io, base.dir, entry, base.dir, target)) return error.OtherHost;
        try h.move.dispatch.directory(.{ .source = base, .target = base, .authorities = &.{ gate.file, held } }, entry, target, parsed.value.purpose, null);
    }
    for ([_][]const u8{ id, draft, bin }) |entry| if (present(base, entry)) {
        base.owns(entry) catch return .unmarked;
        var dir = try base.dir.openDir(base.io, entry, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(base.io);
        var bytes: [h.owner.max_bytes]u8 = undefined;
        const record = h.owner.read(base.io, dir, &bytes) catch return .unmarked;
        var host: [h.machine.limits.host]u8 = undefined;
        const local = h.machine.hostName(&host);
        if (std.mem.eql(u8, local, h.machine.unknown) or !std.mem.eql(u8, local, record.host)) return .other_host;
        try h.rename.settle(base.io, dir);
        return .completed;
    };
    held_open = false;
    try h.lock.retire(base.io, base.dir, id, held);
    return .completed;
}

fn claim(base: *const Base, id: []const u8, record: proof.Record) !void {
    if (!std.mem.eql(u8, &record.nonce, &try h.lease.nonce(base.io, base.dir, id))) return error.IdentityConflict;
    const found = h.name.classify(record.from);
    if (!std.mem.eql(u8, found.id, id) or !record.from_parent.same(try h.move.file.here(base.dir))) return error.IdentityConflict;
    var host: [h.machine.limits.host]u8 = undefined;
    const local = h.machine.hostName(&host);
    if (std.mem.eql(u8, local, h.machine.unknown) or !std.mem.eql(u8, record.host, local) or !std.mem.eql(u8, record.owner_host, local)) return error.OtherHost;
}

fn kept(base: *const Base, id: []const u8, path: []const u8, anchored: bool) anyerror!Status {
    if (base.role != .cache) return error.BadReceipt;
    var target = try Base.existingConfigured(base.allocator, base.io, path, .kept, .{ .native_provider = base.native_provider });
    defer target.close();
    var gates = try h.gates.Pair.acquire(base, &target);
    defer gates.release();
    const held = (try h.lock.take(base.io, base.dir, id)) orelse return .held;
    var held_open = true;
    defer if (held_open) held.close(base.io);
    const arrived = h.lock.create(base.io, target.dir, id) catch |err| switch (err) {
        error.PathAlreadyExists => (try h.lock.take(base.io, target.dir, id)) orelse return .held,
        else => return err,
    };
    defer arrived.close(base.io);
    if (anchored) {
        var buffer: [h.name.limits.component]u8 = undefined;
        const anchor = try proof.anchorName(&buffer, id);
        const parsed = try proof.read(base.allocator, base.io, base.dir, anchor);
        defer parsed.deinit();
        try claim(base, id, parsed.value);
        try h.move.tree.finishRecorded(base.allocator, base.io, base.dir, target.dir, parsed.value);
        try removeAnchor(base, anchor, parsed.value);
    } else {
        if (!try proof.localOwner(base.allocator, base.io, base.dir, id, target.dir, id)) return error.OtherHost;
        var bytes: [h.move.tree.limits.receipt]u8 = undefined;
        const receipt = try h.move.tree.receiptOf(base.io, base.dir, id, &bytes);
        const authorities: []const std.Io.File = if (gates.second) |second| &[_]std.Io.File{ gates.first.file, second.file, held, arrived } else &[_]std.Io.File{ gates.first.file, held, arrived };
        try h.move.dispatch.directory(.{ .source = base, .target = &target, .authorities = authorities }, id, id, receipt, null);
    }
    held_open = false;
    try h.lock.retire(base.io, base.dir, id, held);
    return .completed;
}

fn removeAnchor(base: *const Base, leaf: []const u8, record: proof.Record) !void {
    const now = try h.move.file.state(base.dir, leaf);
    if (!now.same(record.marker) or now.links != 1) return error.IdentityConflict;
    try base.dir.deleteFile(base.io, leaf);
    try h.move.file.syncDir(base.dir);
}
fn present(base: *const Base, leaf: []const u8) bool {
    _ = base.dir.statFile(base.io, leaf, .{ .follow_symlinks = false }) catch return false;
    return true;
}
