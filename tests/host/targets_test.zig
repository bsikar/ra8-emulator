const std = @import("std");

const model = @import("ra8").host.targets;

pub const Log = struct {
    calls: usize = 0,
    fail: bool = false,
    pub fn perform(context: *anyopaque, _: model.Action, _: []u8) ![]const u8 {
        const self: *Log = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.fail) return error.AgentDisconnected;
        return "{\"ok\":true}";
    }
    pub fn provider(self: *Log) model.Provider {
        return .{ .context = self, .performFn = perform };
    }
};

pub fn descriptor(board: []const u8, probe: []const u8) model.Descriptor {
    return .{ .managed = false, .operations = &.{ .registers, .halt, .step, .@"resume" }, .host_id = "fixture-host", .probe_id = probe, .board_id = board, .transport = "rsp", .vendor = "fixture", .model = "same-model", .identity_verified = true, .capabilities = .{ .hardware_debug = true } };
}

pub fn selection(board: []const u8, probe: []const u8, generation: u64) model.Selection {
    return .{ .host_id = "fixture-host", .probe_id = probe, .board_id = board, .generation = generation };
}

test "stable selection routes only selected provider after inventory reorder" {
    var registry: model.Registry = .{};
    var a: Log = .{};
    var b: Log = .{};
    var owner: u8 = 0;
    _ = try registry.add(descriptor("board-a", "probe-a"), a.provider());
    const gen = try registry.add(descriptor("board-b", "probe-b"), b.provider());
    std.mem.swap(?model.Entry, &registry.entries[0], &registry.entries[1]);
    const selected = selection("board-b", "probe-b", gen);
    try registry.reserve(&owner, selected);
    _ = try registry.perform(&owner, selected, .halt, &.{});
    try std.testing.expectEqual(@as(usize, 0), a.calls);
    try std.testing.expectEqual(@as(usize, 1), b.calls);
    try std.testing.expectError(error.Unsupported, registry.perform(&owner, selected, .flash, &.{}));
    try std.testing.expectEqual(@as(usize, 1), b.calls);
}

test "competing clients cannot operate or steal a lease and disconnect releases it" {
    var registry: model.Registry = .{};
    var log: Log = .{};
    var one: u8 = 0;
    var two: u8 = 0;
    const gen = try registry.add(descriptor("board", "probe"), log.provider());
    const selected = selection("board", "probe", gen);
    try registry.reserve(&one, selected);
    try std.testing.expectError(error.TargetBusy, registry.reserve(&two, selected));
    try std.testing.expectError(error.NotReserved, registry.perform(&two, selected, .halt, &.{}));
    registry.release(&two);
    try std.testing.expectError(error.TargetBusy, registry.reserve(&two, selected));
    registry.release(&one);
    try registry.reserve(&two, selected);
}

test "agent loss and reconnect invalidate selection and clean leases" {
    var registry: model.Registry = .{};
    var log: Log = .{};
    var owner: u8 = 0;
    const gen = try registry.add(descriptor("board", "probe"), log.provider());
    const old = selection("board", "probe", gen);
    try registry.reserve(&owner, old);
    registry.disconnect("fixture-host");
    const next = try registry.add(descriptor("board", "probe"), log.provider());
    try std.testing.expectError(error.StaleSelection, registry.reserve(&owner, old));
    const selected = selection("board", "probe", next);
    try registry.reserve(&owner, selected);
    log.fail = true;
    try std.testing.expectError(error.AgentDisconnected, registry.perform(&owner, selected, .halt, &.{}));
    try std.testing.expect(registry.entries[0].?.owner == null);
    try std.testing.expectError(error.Disconnected, registry.reserve(&owner, selected));
}

test "missing identity needs explicit verified disambiguation and managed benches fail closed" {
    var registry: model.Registry = .{};
    var log: Log = .{};
    var owner: u8 = 0;
    var target = descriptor("board", "probe");
    target.identity_verified = false;
    target.disambiguation = "operator-binding-a";
    const gen = try registry.add(target, log.provider());
    var selected = selection("board", "probe", gen);
    try std.testing.expectError(error.AmbiguousIdentity, registry.reserve(&owner, selected));
    selected.disambiguation = "operator-binding-a";
    try registry.reserve(&owner, selected);
    registry.entries[0].?.target.managed = true;
    try std.testing.expectError(error.CustodianUnavailable, registry.perform(&owner, selected, .halt, &.{}));
    registry.release(&owner);
    try std.testing.expectError(error.CustodianUnavailable, registry.reserve(&owner, selected));
    try std.testing.expectEqual(@as(usize, 0), log.calls);
}

test "duplicate board or probe bindings and multiple reservations are rejected" {
    var registry: model.Registry = .{};
    var log: Log = .{};
    var owner: u8 = 0;
    const gen = try registry.add(descriptor("board", "probe"), log.provider());
    try std.testing.expectError(error.DuplicateIdentity, registry.add(descriptor("board", "other"), log.provider()));
    try std.testing.expectError(error.DuplicateIdentity, registry.add(descriptor("other", "probe"), log.provider()));
    const other = try registry.add(descriptor("other", "other"), log.provider());
    try registry.reserve(&owner, selection("board", "probe", gen));
    try std.testing.expectError(error.AlreadyReserved, registry.reserve(&owner, selection("other", "other", other)));
}

test "provider operation metadata is bounded before publication" {
    var registry: model.Registry = .{};
    var log: Log = .{};
    var target = descriptor("board", "probe");
    const operations: [7]model.Action = @splat(.registers);
    target.operations = &operations;
    try std.testing.expectError(error.InvalidCapabilities, registry.add(target, log.provider()));
}

const Hooks = struct {
    claimed: usize = 0,
    released: usize = 0,
    busy: bool = false,
    custodian_token: u64 = 10,
    custodian_released: u64 = 0,
    fn claim(ctx: *anyopaque) !void {
        const self: *Hooks = @ptrCast(@alignCast(ctx));
        if (self.busy) return error.TargetBusy;
        self.claimed += 1;
    }
    fn release(ctx: *anyopaque) void {
        const self: *Hooks = @ptrCast(@alignCast(ctx));
        self.released += 1;
    }
    fn authorize(ctx: *anyopaque, _: model.Descriptor, _: u64) !u64 {
        const self: *Hooks = @ptrCast(@alignCast(ctx));
        return self.custodian_token;
    }
    fn custodianRelease(ctx: *anyopaque, _: model.Descriptor, token: u64) void {
        const self: *Hooks = @ptrCast(@alignCast(ctx));
        self.custodian_released = token;
    }
};

test "hotplug presence bumps generation on connect unplug and UART renumbering" {
    var registry: model.Registry = .{};
    var hooks: Hooks = .{};
    var log: Log = .{};
    var owner: u8 = 0;
    var target = descriptor("board", "probe");
    target.connection = .disconnected;
    target.identity_verified = false;
    _ = try registry.add(target, .{
        .context = &log,
        .performFn = Log.perform,
        .claimFn = @ptrCast(&Hooks.claim),
        .releaseFn = @ptrCast(&Hooks.release),
    });
    registry.entries[0].?.provider = .{
        .context = &hooks,
        .performFn = struct {
            fn f(_: *anyopaque, _: model.Action, _: []u8) ![]const u8 {
                return "{\"ok\":true}";
            }
        }.f,
        .claimFn = Hooks.claim,
        .releaseFn = Hooks.release,
    };
    try registry.present(&registry.entries[0].?, true, "COM13");
    const first = registry.entries[0].?.generation;
    try registry.reserve(&owner, selection("board", "probe", first));
    try std.testing.expectEqual(@as(usize, 1), hooks.claimed);
    try registry.present(&registry.entries[0].?, true, "COM13");
    try std.testing.expectEqual(first, registry.entries[0].?.generation);
    try registry.present(&registry.entries[0].?, false, "");
    try std.testing.expectEqual(@as(usize, 1), hooks.released);
    try std.testing.expect(registry.entries[0].?.owner == null);
    try std.testing.expectError(error.StaleSelection, registry.reserve(&owner, selection("board", "probe", first)));
    try registry.present(&registry.entries[0].?, true, "COM14");
    const replugged = registry.entries[0].?.generation;
    try std.testing.expect(replugged > first);
    try std.testing.expectEqualStrings("COM14", registry.entries[0].?.target.uart);
}

test "custodian hook gates managed targets and releases custodian lease when claim fails" {
    var registry: model.Registry = .{};
    var hooks: Hooks = .{};
    var owner: u8 = 0;
    var target = descriptor("board", "probe");
    target.managed = true;
    const gen = try registry.add(target, .{
        .context = &hooks,
        .performFn = struct {
            fn f(_: *anyopaque, _: model.Action, _: []u8) ![]const u8 {
                return "{\"ok\":true}";
            }
        }.f,
        .claimFn = Hooks.claim,
        .releaseFn = Hooks.release,
    });
    const sel = selection("board", "probe", gen);
    try std.testing.expectError(error.CustodianUnavailable, registry.reserve(&owner, sel));
    registry.custodian = .{
        .context = &hooks,
        .authorizeFn = Hooks.authorize,
        .releaseFn = Hooks.custodianRelease,
    };
    hooks.busy = true;
    try std.testing.expectError(error.TargetBusy, registry.reserve(&owner, sel));
    try std.testing.expectEqual(@as(u64, 10), hooks.custodian_released);
    hooks.busy = false;
    hooks.custodian_token = 22;
    try registry.reserve(&owner, sel);
    _ = try registry.perform(&owner, sel, .halt, &.{});
    registry.release(&owner);
    try std.testing.expectEqual(@as(u64, 22), hooks.custodian_released);
}

const FlashMock = struct {
    flashes: usize = 0,
    mode: enum { ok, bad_elf, hw_fail } = .ok,
    fn perform(_: *anyopaque, _: model.Action, _: []u8) ![]const u8 {
        return "{\"ok\":true}";
    }
    fn flash(ctx: *anyopaque, elf: []const u8, out: []u8) ![]const u8 {
        const self: *FlashMock = @ptrCast(@alignCast(ctx));
        self.flashes += 1;
        return switch (self.mode) {
            .ok => std.fmt.bufPrint(out, "{{\"flashed\":true,\"bytes\":{d}}}", .{elf.len}),
            .bad_elf => error.AddressOutOfRange,
            .hw_fail => error.FlashFailed,
        };
    }
};

test "Registry.flash preserves reservation on artifact rejection and fences on hardware failure" {
    var registry: model.Registry = .{};
    var mock: FlashMock = .{ .mode = .bad_elf };
    var owner: u8 = 0;
    var target = descriptor("board-f", "probe-f");
    target.operations = &.{ .registers, .flash, .reset };
    target.capabilities = .{ .hardware_debug = true, .flash = true };
    const gen = try registry.add(target, .{
        .context = &mock,
        .performFn = FlashMock.perform,
        .flashFn = FlashMock.flash,
    });
    const sel = selection("board-f", "probe-f", gen);
    try registry.reserve(&owner, sel);
    var out: [128]u8 = undefined;

    // Input rejection keeps target connected and reserved.
    try std.testing.expectError(error.AddressOutOfRange, registry.flash(&owner, sel, "bad", &out));
    try std.testing.expect(registry.entries[0].?.owner == @as(*anyopaque, &owner));

    mock.mode = .ok;
    const res = try registry.flash(&owner, sel, "elfbytes", &out);
    try std.testing.expectEqualStrings("{\"flashed\":true,\"bytes\":8}", res);

    // Hardware failure fences target disconnected and releases ownership.
    mock.mode = .hw_fail;
    try std.testing.expectError(error.FlashFailed, registry.flash(&owner, sel, "elfbytes", &out));
    try std.testing.expect(registry.entries[0].?.owner == null);
    try std.testing.expectEqual(.disconnected, registry.entries[0].?.target.connection);
}
