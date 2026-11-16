//! Trusted host registrations, stable identity selection and connection-owned reservations.
//! The host serializes calls and retains descriptor/provider storage until removal.
const std = @import("std");

pub const Action = enum(u8) { registers, halt, step, @"resume", flash, reset };
pub const Capabilities = struct {
    build: bool = false,
    flash: bool = false,
    hardware_debug: bool = false,
    emulation: bool = false,
    npu: bool = false,
};
pub const Descriptor = struct {
    host_id: []const u8,
    probe_id: []const u8,
    board_id: []const u8,
    probe_serial: []const u8 = "",
    board_serial: []const u8 = "",
    vendor: []const u8 = "",
    model: []const u8 = "",
    cores: []const u8 = "",
    transport: []const u8,
    connection: enum { configured, connected, disconnected } = .configured,
    /// Missing physical identity requires an operator-assigned, physically verified binding.
    disambiguation: []const u8 = "",
    identity_verified: bool = false,
    managed: bool,
    operations: []const Action = &.{},
    capabilities: Capabilities = .{},
};
pub const Selection = struct {
    host_id: []const u8,
    probe_id: []const u8,
    board_id: []const u8,
    generation: u64,
    disambiguation: []const u8 = "",
};
pub const Provider = struct {
    context: *anyopaque,
    performFn: *const fn (*anyopaque, Action, []u8) anyerror![]const u8,
};
pub const Entry = struct {
    target: Descriptor,
    generation: u64,
    provider: Provider,
    owner: ?*anyopaque = null,
};
pub const Registry = struct {
    entries: [32]?Entry = @splat(null),
    generation: u64 = 0,

    pub fn add(self: *Registry, target: Descriptor, provider: Provider) !u64 {
        try validate(target);
        for (self.entries) |slot| if (slot) |entry| {
            if (std.mem.eql(u8, entry.target.board_id, target.board_id) or
                (std.mem.eql(u8, entry.target.host_id, target.host_id) and
                    std.mem.eql(u8, entry.target.probe_id, target.probe_id))) return error.DuplicateIdentity;
        };
        for (&self.entries) |*slot| if (slot.* == null) {
            self.generation = std.math.add(u64, self.generation, 1) catch return error.GenerationExhausted;
            slot.* = .{ .target = target, .generation = self.generation, .provider = provider };
            return self.generation;
        };
        return error.InventoryFull;
    }

    /// Agent loss removes every binding and its lease. Reconnect gets fresh generations.
    pub fn disconnect(self: *Registry, host_id: []const u8) void {
        for (&self.entries) |*slot| if (slot.*) |entry| {
            if (std.mem.eql(u8, entry.target.host_id, host_id)) slot.* = null;
        };
    }

    pub fn find(self: *Registry, selection: Selection) !*Entry {
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            const t = entry.target;
            if (!matches(t, selection)) continue;
            try checkSelection(entry, selection);
            return entry;
        };
        return error.StaleSelection;
    }

    pub fn reserve(self: *Registry, owner: *anyopaque, selection: Selection) !void {
        const entry = try self.find(selection);
        // No direct fallback: RA8CI custodian integration is required for managed benches.
        if (entry.target.managed) return error.CustodianUnavailable;
        if (entry.owner) |held| if (held != owner) return error.TargetBusy;
        for (self.entries) |slot| if (slot) |held| {
            if (held.owner == owner and held.generation != entry.generation) return error.AlreadyReserved;
        };
        entry.owner = owner;
    }

    pub fn release(self: *Registry, owner: *anyopaque) void {
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            if (entry.owner == owner) entry.owner = null;
        };
    }

    pub fn perform(self: *Registry, owner: *anyopaque, selection: Selection, action: Action, out: []u8) ![]const u8 {
        const entry = try self.find(selection);
        if (entry.target.managed) return error.CustodianUnavailable;
        if (entry.owner != owner) return error.NotReserved;
        if (std.mem.indexOfScalar(Action, entry.target.operations, action) == null) return error.Unsupported;
        const caps = entry.target.capabilities;
        const supported = switch (action) {
            .flash => caps.flash,
            .reset => false,
            else => caps.hardware_debug or caps.emulation,
        };
        if (!supported) return error.Unsupported;
        return entry.provider.performFn(entry.provider.context, action, out) catch |err| {
            if (err != error.Unsupported) {
                entry.target.connection = .disconnected;
                entry.owner = null;
            }
            return err;
        };
    }
};

fn validate(target: Descriptor) !void {
    if (target.operations.len > @typeInfo(Action).@"enum".field_names.len) return error.InvalidCapabilities;
    inline for (.{ "host_id", "probe_id", "board_id", "transport" }) |field| {
        const value = @field(target, field);
        if (value.len == 0 or value.len > 128) return error.InvalidIdentity;
        for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and
            byte != '.' and byte != ':') return error.InvalidIdentity;
    }
    inline for (.{ "probe_serial", "board_serial", "vendor", "model", "cores", "disambiguation" }) |field| {
        if (@field(target, field).len > 128) return error.InvalidIdentity;
    }
}

fn matches(target: Descriptor, selection: Selection) bool {
    return std.mem.eql(u8, target.host_id, selection.host_id) and
        std.mem.eql(u8, target.probe_id, selection.probe_id) and
        std.mem.eql(u8, target.board_id, selection.board_id);
}

fn checkSelection(entry: *const Entry, selection: Selection) !void {
    if (entry.generation != selection.generation) return error.StaleSelection;
    const target = entry.target;
    if (!target.identity_verified and (target.disambiguation.len == 0 or
        !std.mem.eql(u8, target.disambiguation, selection.disambiguation))) return error.AmbiguousIdentity;
    if (target.connection == .disconnected) return error.Disconnected;
}
