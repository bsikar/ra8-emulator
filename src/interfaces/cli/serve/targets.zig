//! Operator-owned bindings, never USB enumeration order or client-supplied endpoints.
const std = @import("std");

const agent = @import("agent.zig");
const api = @import("ra8_session").api;
const auth = @import("ra8_host").probe_host.auth;
const Context = @import("ra8_rpc").session.server.Context;
const jlink = @import("jlink.zig");
const model = @import("ra8_host").targets;
const probe = @import("../probe_ctl.zig");

pub const Binding = struct {
    target: model.Descriptor,
    kind: enum { emulator, rsp, jlink, agent },
    host: []const u8 = "",
    port: u16 = 0,
    secret_file: []const u8 = "",
    program: []const u8 = "",
    scratch: []const u8 = "",
    device: []const u8 = "",
    cpuid: []const u8 = "",
};
pub const Provider = struct {
    binding: Binding,
    io: std.Io,
    session: ?*api.Session,

    fn perform(context: *anyopaque, action: model.Action, out: []u8) ![]const u8 {
        const self: *Provider = @ptrCast(@alignCast(context));
        var writer: std.Io.Writer = .fixed(out);
        if (self.binding.kind == .rsp) {
            const request: probe.Request = .{
                .host = self.binding.host,
                .port = self.binding.port,
                .action = switch (action) {
                    .registers => .registers,
                    .halt => .halt,
                    .step => .step,
                    .@"resume" => .cont,
                    else => return error.Unsupported,
                },
            };
            try probe.execute(self.io, request, &writer);
        } else {
            const session = self.session orelse return error.Unsupported;
            switch (action) {
                .halt => {
                    try session.pause(.cpu0);
                    try writer.writeAll("{\"halted\":true}");
                },
                .step => {
                    _ = try session.step(.cpu0);
                    try writer.writeAll("{\"stepped\":true}");
                },
                .registers => try writer.print("{{\"pc\":{d}}}", .{try session.register(.cpu0, .pc)}),
                else => return error.Unsupported,
            }
        }
        return std.mem.trimEnd(u8, writer.buffered(), "\r\n");
    }
};
pub const Inventory = struct {
    registry: model.Registry = .{},
    providers: [32]Provider = undefined,
    probes: [32]jlink.Probe = undefined,
    probe_count: usize = 0,
    agent_hosts: [16]agent.Host = undefined,
    agent_host_count: usize = 0,
    agent_targets: [32]agent.Target = undefined,
    agent_target_count: usize = 0,
    parsed: ?std.json.Parsed([]Binding) = null,

    pub fn open(
        self: *Inventory,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        session: ?*api.Session,
    ) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(65536));
        defer allocator.free(bytes);
        self.parsed = try std.json.parseFromSlice([]Binding, allocator, bytes, .{ .allocate = .alloc_always });
        errdefer self.close();
        const bindings = self.parsed.?.value;
        if (bindings.len > self.providers.len) return error.InventoryFull;
        var nonce: [8]u8 = undefined;
        io.random(&nonce);
        self.registry.generation = std.mem.readInt(u64, &nonce, .little) >> 1;
        var emulator = false;
        for (bindings, 0..) |binding, i| {
            const descriptor = try describe(binding);
            switch (binding.kind) {
                .jlink => try self.addProbe(io, descriptor, binding),
                .agent => try self.addAgent(io, bindings[0..i], descriptor, binding),
                .emulator => {
                    if (session == null) return error.InvalidEndpoint;
                    if (emulator) return error.DuplicateEmulator;
                    emulator = true;
                    self.providers[i] = .{ .binding = binding, .io = io, .session = session };
                    _ = try self.registry.add(descriptor, .{
                        .context = &self.providers[i],
                        .performFn = Provider.perform,
                    });
                },
                .rsp => {
                    try uniqueEndpoint(bindings[0..i], binding);
                    self.providers[i] = .{ .binding = binding, .io = io, .session = session };
                    _ = try self.registry.add(descriptor, .{
                        .context = &self.providers[i],
                        .performFn = Provider.perform,
                    });
                },
            }
        }
        if (self.probe_count == 0 and self.agent_target_count == 0) return;
        self.registry.scanner = .{ .context = self, .scanFn = scanAll };
        self.registry.refresh();
    }

    fn scanAll(context: *anyopaque, registry: *model.Registry) void {
        const self: *Inventory = @ptrCast(@alignCast(context));
        jlink.scanProbes(self.probes[0..self.probe_count], registry);
        agent.scanHosts(
            self.agent_hosts[0..self.agent_host_count],
            self.agent_targets[0..self.agent_target_count],
            registry,
        );
    }

    fn addProbe(self: *Inventory, io: std.Io, descriptor: model.Descriptor, binding: Binding) !void {
        const probe_state = try jlink.configure(io, descriptor, binding);
        for (self.probes[0..self.probe_count]) |other| {
            if (other.serial == probe_state.serial) return error.DuplicateIdentity;
        }
        self.probes[self.probe_count] = probe_state;
        _ = try self.registry.add(descriptor, self.probes[self.probe_count].provider());
        self.probe_count += 1;
    }

    fn addAgent(
        self: *Inventory,
        io: std.Io,
        previous: []const Binding,
        descriptor: model.Descriptor,
        binding: Binding,
    ) !void {
        try uniqueEndpoint(previous, binding);
        for (self.agent_targets[0..self.agent_target_count]) |other| {
            if (std.mem.eql(u8, other.descriptor.board_id, descriptor.board_id) or
                (std.mem.eql(u8, other.descriptor.host_id, descriptor.host_id) and
                    std.mem.eql(u8, other.descriptor.probe_id, descriptor.probe_id))) return error.DuplicateIdentity;
        }
        const peer = try self.ensureAgentHost(io, descriptor.host_id, binding);
        self.agent_targets[self.agent_target_count] = .{ .descriptor = descriptor, .peer = peer };
        self.agent_target_count += 1;
    }

    fn ensureAgentHost(self: *Inventory, io: std.Io, host_id: []const u8, binding: Binding) !*agent.Host {
        for (self.agent_hosts[0..self.agent_host_count]) |*existing| {
            if (!std.mem.eql(u8, existing.host_id, host_id)) continue;
            if (!std.mem.eql(u8, existing.address, binding.host) or existing.port != binding.port or
                !std.mem.eql(u8, existing.secret_file, binding.secret_file)) return error.InvalidEndpoint;
            return existing;
        }
        if (self.agent_host_count == self.agent_hosts.len) return error.InventoryFull;
        const key = try auth.readKey(io, binding.secret_file);
        self.agent_hosts[self.agent_host_count] = .{
            .io = io,
            .host_id = host_id,
            .address = binding.host,
            .port = binding.port,
            .secret_file = binding.secret_file,
            .key = key,
        };
        const slot = &self.agent_hosts[self.agent_host_count];
        self.agent_host_count += 1;
        return slot;
    }

    pub fn bind(
        self: *Inventory,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: ?[]const u8,
        context: *Context,
    ) !void {
        const file = path orelse return;
        try self.open(allocator, io, file, context.session);
        context.targets = &self.registry;
    }

    pub fn close(self: *Inventory) void {
        for (&self.registry.entries) |*slot| if (slot.*) |*entry| {
            if (entry.owner) |owner| self.registry.release(owner);
        };
        for (self.agent_hosts[0..self.agent_host_count]) |*peer| {
            peer.close();
        }
        if (self.parsed) |parsed| parsed.deinit();
        self.parsed = null;
        self.registry.entries = @splat(null);
        self.registry.scanner = null;
        self.probe_count = 0;
        self.agent_host_count = 0;
        self.agent_target_count = 0;
    }
};

fn uniqueEndpoint(previous: []const Binding, binding: Binding) !void {
    for (previous) |other| {
        if ((other.kind != .rsp and other.kind != .agent) or other.port != binding.port) continue;
        if (!std.mem.eql(u8, other.host, binding.host)) continue;
        if (binding.kind == .agent and other.kind == .agent and
            std.mem.eql(u8, other.target.host_id, binding.target.host_id)) continue;
        return error.DuplicateEndpoint;
    }
}

fn describe(binding: Binding) !model.Descriptor {
    var descriptor = binding.target;
    // Capability claims come from this adapter, never configuration data.
    descriptor.capabilities = .{};
    descriptor.connection = .configured;
    descriptor.uart = "";
    switch (binding.kind) {
        .rsp => {
            if (binding.port == 0 or binding.host.len == 0) return error.InvalidEndpoint;
            if (!std.mem.eql(u8, descriptor.transport, "rsp")) return error.InvalidEndpoint;
            descriptor.operations = &.{ .registers, .halt, .step, .@"resume" };
            descriptor.capabilities.hardware_debug = true;
        },
        .emulator => {
            if (!std.mem.eql(u8, descriptor.transport, "in-process")) return error.InvalidEndpoint;
            descriptor.operations = &.{ .registers, .halt, .step };
            descriptor.capabilities.emulation = true;
            descriptor.connection = .connected;
        },
        .jlink => {
            descriptor.identity_verified = false;
            descriptor.disambiguation = "";
            descriptor.operations = jlink.operations;
            descriptor.capabilities.hardware_debug = true;
        },
        .agent => {
            if (binding.port == 0 or binding.host.len == 0 or binding.secret_file.len == 0) {
                return error.InvalidEndpoint;
            }
            if (!std.fs.path.isAbsolute(binding.secret_file)) return error.InvalidEndpoint;
            descriptor.identity_verified = false;
            descriptor.connection = .disconnected;
            descriptor.operations = &.{};
        },
    }
    return descriptor;
}
