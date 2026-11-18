//! Onboard J-Link targets: presence and the UART come from a USB scan keyed
//! by the operator-pinned probe serial, ownership from a host-wide lease, and
//! every operation names the probe by serial and checks the expected core.
const std = @import("std");

const host = @import("ra8_host");

const commander = host.jlink.commander;
const emu_list = host.jlink.emu_list;
const model = host.targets;
const target_lease = host.target_lease;

pub const transport = "jlink-usb";
pub const operations: []const model.Action = &.{ .registers, .halt, .step, .@"resume", .reset };

pub const Probe = struct {
    io: std.Io,
    serial: u64,
    tool: commander.Tool,
    device: []const u8,
    cpuid: u32,
    lease: ?target_lease.Lease = null,
    fence: target_lease.Fence = .{},
    uart: [2][64]u8 = undefined,

    pub fn provider(self: *Probe) model.Provider {
        return .{ .context = self, .performFn = perform, .claimFn = claim, .releaseFn = release };
    }

    fn perform(context: *anyopaque, action: model.Action, out: []u8) ![]const u8 {
        const self: *Probe = @ptrCast(@alignCast(context));
        const lease = self.lease orelse return error.NotReserved;
        try self.fence.admit(lease.token);
        var text: [16384]u8 = undefined;
        const outcome = try commander.operate(self.io, self.tool, self.serial, self.device, self.cpuid, action, &text);
        return formatOutcome(action, outcome, lease.token, out);
    }

    fn claim(context: *anyopaque) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        var key: [32]u8 = undefined;
        var digits: [20]u8 = undefined;
        const name = try std.fmt.bufPrint(&key, "jlink-{s}", .{emu_list.format(self.serial, &digits)});
        self.lease = try target_lease.Lease.acquire(self.io, self.tool.scratch, name);
    }

    fn release(context: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        if (self.lease) |*lease| lease.close(self.io);
        self.lease = null;
    }

    /// The port for this probe, written to the buffer `current` does not use.
    fn port(self: *Probe, current: []const u8) []const u8 {
        const side: usize = if (current.len != 0 and @intFromPtr(current.ptr) == @intFromPtr(&self.uart[0])) 1 else 0;
        const found = host.jlink.uart.find(self.io, self.serial, &self.uart[side]) catch null;
        return found orelse "";
    }
};

fn formatOutcome(action: model.Action, outcome: commander.Outcome, token: u64, out: []u8) ![]const u8 {
    var digits: [20]u8 = undefined;
    const serial = emu_list.format(outcome.identity.serial, &digits);
    const cpuid = outcome.identity.cpuid;
    return switch (action) {
        .registers => std.fmt.bufPrint(
            out,
            "{{\"serial\":\"{s}\",\"cpuid\":\"0x{X:0>8}\",\"pc\":{d},\"sp\":{d},\"lease\":{d}}}",
            .{ serial, cpuid, outcome.registers.?.pc, outcome.registers.?.sp, token },
        ),
        .halt => std.fmt.bufPrint(
            out,
            "{{\"halted\":true,\"serial\":\"{s}\",\"cpuid\":\"0x{X:0>8}\",\"pc\":{d},\"lease\":{d}}}",
            .{ serial, cpuid, outcome.registers.?.pc, token },
        ),
        .step => std.fmt.bufPrint(
            out,
            "{{\"stepped\":true,\"serial\":\"{s}\",\"cpuid\":\"0x{X:0>8}\",\"pc\":{d},\"lease\":{d}}}",
            .{ serial, cpuid, outcome.registers.?.pc, token },
        ),
        .@"resume" => std.fmt.bufPrint(
            out,
            "{{\"resumed\":true,\"serial\":\"{s}\",\"cpuid\":\"0x{X:0>8}\",\"lease\":{d}}}",
            .{ serial, cpuid, token },
        ),
        .reset => std.fmt.bufPrint(
            out,
            "{{\"reset\":true,\"serial\":\"{s}\",\"cpuid\":\"0x{X:0>8}\",\"lease\":{d}}}",
            .{ serial, cpuid, token },
        ),
        .flash => error.Unsupported,
    };
}

pub fn scanProbes(probes: []Probe, registry: *model.Registry) void {
    if (probes.len == 0) return;
    var seen: [32]emu_list.Probe = undefined;
    var text: [16384]u8 = undefined;
    const first = probes[0];
    const listed = commander.list(first.io, first.tool, &seen, &text) catch &.{};
    apply(registry, probes, listed);
}

/// Marks each J-Link entry present exactly when its serial was listed.
pub fn apply(registry: *model.Registry, probes: []Probe, listed: []const emu_list.Probe) void {
    for (&registry.entries) |*slot| {
        if (slot.*) |*entry| applyEntry(registry, probes, listed, entry);
    }
}

fn applyEntry(
    registry: *model.Registry,
    probes: []Probe,
    listed: []const emu_list.Probe,
    entry: *model.Entry,
) void {
    const probe = owned(probes, entry.provider.context) orelse return;
    const here = containsSerial(listed, probe.serial);
    const uart = if (here) probe.port(entry.target.uart) else "";
    registry.present(entry, here, uart) catch return;
}

fn containsSerial(listed: []const emu_list.Probe, serial: u64) bool {
    for (listed) |seen| {
        if (seen.serial == serial) return true;
    }
    return false;
}

fn owned(probes: []Probe, context: *anyopaque) ?*Probe {
    for (probes) |*probe| if (@as(*anyopaque, probe) == context) return probe;
    return null;
}

/// Validates an operator binding's J-Link fields.
pub fn configure(io: std.Io, target: model.Descriptor, fields: anytype) !Probe {
    if (!std.mem.eql(u8, target.transport, transport)) return error.InvalidEndpoint;
    if (fields.program.len == 0 or fields.scratch.len == 0 or fields.device.len == 0) return error.InvalidEndpoint;
    if (!std.fs.path.isAbsolute(fields.scratch)) return error.InvalidEndpoint;
    const hex = if (std.mem.startsWith(u8, fields.cpuid, "0x")) fields.cpuid[2..] else return error.InvalidEndpoint;
    return .{
        .io = io,
        .serial = try emu_list.serialOf(target.probe_serial),
        .tool = .{ .program = fields.program, .scratch = fields.scratch },
        .device = fields.device,
        .cpuid = std.fmt.parseInt(u32, hex, 16) catch return error.InvalidEndpoint,
    };
}
