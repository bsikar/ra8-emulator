//! Authenticated probe-host adapter: connects to an operator-pinned native
//! probe-host over a mutually-authenticated HMAC-SHA256 session, mirrors its
//! target presence into the host Registry, forwards fenced claims/actions, and
//! calls `Registry.disconnect(host_id)` whenever the agent link is lost.
const std = @import("std");

const host = @import("ra8_host");

const auth = host.probe_host.auth;
const model = host.targets;
const wire = host.probe_host.wire;

pub const Host = struct {
    io: std.Io,
    host_id: []const u8,
    address: []const u8,
    port: u16,
    secret_file: []const u8,
    key: auth.Key,
    stream: ?std.Io.net.Stream = null,
    lost: bool = false,

    pub fn close(self: *Host) void {
        if (self.stream) |stream| stream.close(self.io);
        self.stream = null;
    }

    pub fn request(
        self: *Host,
        allocator: std.mem.Allocator,
        req: wire.Request,
        scratch: []u8,
    ) !std.json.Parsed(wire.Reply) {
        try self.ensureConnected();
        return self.exchange(allocator, req, scratch) catch |err| {
            self.lost = true;
            self.close();
            return err;
        };
    }

    fn ensureConnected(self: *Host) !void {
        if (self.stream != null) return;
        const remote = try std.Io.net.HostName.init(self.address);
        var stream = try remote.connect(self.io, self.port, .{ .mode = .stream });
        errdefer stream.close(self.io);
        var tx_buf: [1024]u8 = undefined;
        var rx_buf: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &tx_buf);
        var reader = stream.reader(self.io, &rx_buf);
        try auth.authenticateClient(self.io, &reader.interface, &writer.interface, self.host_id, self.key);
        self.stream = stream;
    }

    fn exchange(
        self: *Host,
        allocator: std.mem.Allocator,
        req: wire.Request,
        scratch: []u8,
    ) !std.json.Parsed(wire.Reply) {
        var stream = self.stream orelse return error.AgentDisconnected;
        var tx_buf: [2048]u8 = undefined;
        var writer = stream.writer(self.io, &tx_buf);
        wire.send(&writer.interface, req) catch return error.AgentDisconnected;
        return wire.receiveSocket(wire.Reply, allocator, self.io, stream.socket.handle, scratch, 20_000);
    }
};

pub const Target = struct {
    descriptor: model.Descriptor,
    peer: *Host,
    token: u64 = 0,
    uart: [2][64]u8 = undefined,
    ops: [6]model.Action = undefined,

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
        if (token == 0 or self.peer.stream == null) return;
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
