//! Authenticated probe-host adapter (`RA8PH2` per-frame HMAC-SHA256): connects
//! over TCP or a `ra8_host.profiles` (`local` / `ssh`) `probe-agent --stdio`
//! session, mirrors remote target presence into `Registry`, consumes bounded
//! streamed progress/UART chunks, and calls `Registry.disconnect(host_id)`
//! whenever the agent link fails or disconnects.
const std = @import("std");

const agent_link = @import("agent_link.zig");
const host = @import("ra8_host");

const auth = host.probe_host.auth;
const model = host.targets;
const wire = host.probe_host.wire;

pub const Host = struct {
    io: std.Io,
    host_id: []const u8,
    spec: agent_link.Spec,
    secret_file: []const u8,
    key: auth.Key,
    link: agent_link.Link = .closed,
    lost: bool = false,
    chunks_seen: usize = 0,

    pub fn close(self: *Host) void {
        self.link.close(self.io);
    }

    pub fn request(
        self: *Host,
        allocator: std.mem.Allocator,
        req: wire.Request,
        scratch: []u8,
    ) !std.json.Parsed(wire.Reply) {
        try self.link.connect(self.io, self.spec, self.host_id, self.key);
        return self.exchange(allocator, req, scratch) catch |err| {
            self.lost = true;
            self.close();
            return err;
        };
    }

    fn exchange(
        self: *Host,
        allocator: std.mem.Allocator,
        req: wire.Request,
        scratch: []u8,
    ) !std.json.Parsed(wire.Reply) {
        try self.link.send(self.io, req);
        var chunks: usize = 0;
        while (true) {
            const parsed = try self.link.receive(allocator, self.io, scratch, 25_000);
            if (!parsed.value.chunk) {
                self.chunks_seen += chunks;
                return parsed;
            }
            parsed.deinit();
            chunks += 1;
            if (chunks > wire.max_chunks) return error.TooManyChunks;
        }
    }
};

pub const Target = struct {
    descriptor: model.Descriptor,
    peer: *Host,
    token: u64 = 0,
    uart: [2][64]u8 = undefined,
    ops: [7]model.Action = undefined,

    pub fn provider(self: *Target) model.Provider {
        return .{ .context = self, .performFn = perform, .claimFn = claim, .releaseFn = release };
    }

    fn claim(context: *anyopaque) !void {
        const self: *Target = @ptrCast(@alignCast(context));
        var scratch: [wire.max_line]u8 = undefined;
        const parsed = try self.peer.request(std.heap.page_allocator, .{
            .op = .claim,
            .probe_id = self.descriptor.probe_id,
            .board_id = self.descriptor.board_id,
        }, &scratch);
        defer parsed.deinit();
        if (!parsed.value.ok) return wire.mapError(parsed.value.err);
        if (parsed.value.token == 0) return error.BadLease;
        self.token = parsed.value.token;
    }

    fn release(context: *anyopaque) void {
        const self: *Target = @ptrCast(@alignCast(context));
        const token = self.token;
        self.token = 0;
        if (token == 0 or !self.peer.link.isOpen()) return;
        var scratch: [4096]u8 = undefined;
        const parsed = self.peer.request(std.heap.page_allocator, .{
            .op = .release,
            .probe_id = self.descriptor.probe_id,
            .board_id = self.descriptor.board_id,
            .token = token,
        }, &scratch) catch return;
        parsed.deinit();
    }

    fn perform(context: *anyopaque, action: model.Action, out: []u8) ![]const u8 {
        const self: *Target = @ptrCast(@alignCast(context));
        if (self.token == 0) return error.NotReserved;
        var scratch: [wire.max_line]u8 = undefined;
        const parsed = try self.peer.request(std.heap.page_allocator, .{
            .op = .perform,
            .probe_id = self.descriptor.probe_id,
            .board_id = self.descriptor.board_id,
            .token = self.token,
            .action = action,
        }, &scratch);
        defer parsed.deinit();
        if (!parsed.value.ok) return wire.mapError(parsed.value.err);
        if (parsed.value.json.len > out.len) return error.TooLarge;
        @memcpy(out[0..parsed.value.json.len], parsed.value.json);
        return out[0..parsed.value.json.len];
    }

    fn savePort(self: *Target, current: []const u8, port: []const u8) []const u8 {
        if (port.len == 0 or port.len > self.uart[0].len) return "";
        const side: usize = if (current.len != 0 and @intFromPtr(current.ptr) == @intFromPtr(&self.uart[0])) 1 else 0;
        @memcpy(self.uart[side][0..port.len], port);
        return self.uart[side][0..port.len];
    }
};

pub fn scanHosts(hosts: []Host, targets: []Target, registry: *model.Registry) void {
    for (hosts) |*peer| {
        if (peer.lost) {
            peer.lost = false;
            registry.disconnect(peer.host_id);
        }
        syncHost(peer, targets, registry) catch {
            peer.lost = false;
            peer.close();
            registry.disconnect(peer.host_id);
        };
    }
}

fn syncHost(peer: *Host, targets: []Target, registry: *model.Registry) !void {
    var scratch: [wire.max_line]u8 = undefined;
    const parsed = try peer.request(std.heap.page_allocator, .{ .op = .list }, &scratch);
    defer parsed.deinit();
    if (!parsed.value.ok) return error.ProbeHostFailed;
    for (targets) |*item| {
        if (item.peer != peer) continue;
        const snap = findSnapshot(parsed.value.targets, item.descriptor);
        try applySnapshot(registry, item, snap);
    }
}

fn findSnapshot(list: []const wire.Snapshot, target: model.Descriptor) ?wire.Snapshot {
    for (list) |snap| {
        if (!std.mem.eql(u8, snap.probe_id, target.probe_id)) continue;
        if (!std.mem.eql(u8, snap.board_id, target.board_id)) continue;
        if (target.probe_serial.len != 0 and !std.mem.eql(u8, snap.probe_serial, target.probe_serial)) continue;
        return snap;
    }
    return null;
}

fn applySnapshot(registry: *model.Registry, item: *Target, maybe: ?wire.Snapshot) !void {
    const entry = findEntry(registry, item) orelse blk: {
        var initial = item.descriptor;
        initial.connection = .disconnected;
        initial.identity_verified = false;
        _ = try registry.add(initial, item.provider());
        break :blk findEntry(registry, item) orelse return;
    };
    const snap = maybe orelse {
        try registry.present(entry, false, "");
        return;
    };
    if (snap.operations.len > item.ops.len) return error.InvalidCapabilities;
    @memcpy(item.ops[0..snap.operations.len], snap.operations);
    entry.target.operations = item.ops[0..snap.operations.len];
    entry.target.capabilities = snap.capabilities;
    const port = if (snap.connected) item.savePort(entry.target.uart, snap.uart) else "";
    try registry.present(entry, snap.connected, port);
    if (!snap.identity_verified) entry.target.identity_verified = false;
}

fn findEntry(registry: *model.Registry, item: *Target) ?*model.Entry {
    for (&registry.entries) |*slot| if (slot.*) |*entry| {
        if (entry.provider.context == @as(*anyopaque, item)) return entry;
    };
    return null;
}
