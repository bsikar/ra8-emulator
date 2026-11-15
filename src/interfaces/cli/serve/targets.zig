//! Operator-owned bindings, never USB enumeration order or client-supplied endpoints.
const std = @import("std");

const api = @import("ra8_session").api;
const Context = @import("ra8_rpc").session.server.Context;
const model = @import("ra8_host").targets;
const probe = @import("../probe_ctl.zig");

pub const Binding = struct {
    target: model.Descriptor,
    kind: enum { emulator, rsp },
    host: []const u8 = "",
    port: u16 = 0,
};
pub const Provider = struct {
    binding: Binding,
    io: std.Io,
    session: *api.Session,

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
        } else switch (action) {
            .halt => {
                try self.session.pause(.cpu0);
                try writer.writeAll("{\"halted\":true}");
            },
            .step => {
                _ = try self.session.step(.cpu0);
                try writer.writeAll("{\"stepped\":true}");
            },
            .registers => try writer.print("{{\"pc\":{d}}}", .{try self.session.register(.cpu0, .pc)}),
            else => return error.Unsupported,
        }
        return std.mem.trimEnd(u8, writer.buffered(), "\r\n");
    }
};
pub const Inventory = struct {
    registry: model.Registry = .{},
    providers: [32]Provider = undefined,
    parsed: ?std.json.Parsed([]Binding) = null,

    pub fn open(
        self: *Inventory,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        session: *api.Session,
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
            if (binding.kind == .emulator) {
                if (emulator) return error.DuplicateEmulator;
                emulator = true;
            } else try uniqueEndpoint(bindings[0..i], binding);
            self.providers[i] = .{ .binding = binding, .io = io, .session = session };
            _ = try self.registry.add(descriptor, .{ .context = &self.providers[i], .performFn = Provider.perform });
        }
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
        if (self.parsed) |parsed| parsed.deinit();
        self.parsed = null;
        self.registry.entries = @splat(null);
    }
};

fn uniqueEndpoint(previous: []const Binding, binding: Binding) !void {
    for (previous) |other| {
        if (other.kind == .rsp and other.port == binding.port and
            std.mem.eql(u8, other.host, binding.host)) return error.DuplicateEndpoint;
    }
}

fn describe(binding: Binding) !model.Descriptor {
    var descriptor = binding.target;
    // Capability claims come from this adapter, never configuration data.
    descriptor.capabilities = .{};
    descriptor.connection = .configured;
    if (binding.kind == .rsp) {
        if (binding.port == 0 or binding.host.len == 0) return error.InvalidEndpoint;
        if (!std.mem.eql(u8, descriptor.transport, "rsp")) return error.InvalidEndpoint;
        descriptor.operations = &.{ .registers, .halt, .step, .@"resume" };
        descriptor.capabilities.hardware_debug = true;
    } else {
        if (!std.mem.eql(u8, descriptor.transport, "in-process")) return error.InvalidEndpoint;
        descriptor.operations = &.{ .registers, .halt, .step };
        descriptor.capabilities.emulation = true;
        descriptor.connection = .connected;
    }
    return descriptor;
}
