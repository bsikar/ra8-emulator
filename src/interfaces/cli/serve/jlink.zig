//! Onboard J-Link targets: presence and the probe CDC interface come from a
//! USB scan keyed by the operator-pinned probe serial, ownership from a
//! host-wide lease, and every operation names the probe by serial and checks
//! the expected core before executing or writing flash.
const builtin = @import("builtin");
const std = @import("std");

const host = @import("ra8_host");

const commander = host.jlink.commander;
const emu_list = host.jlink.emu_list;
const identity = host.jlink.identity;
const model = host.targets;
const serial_port = host.jlink.serial;
const target_lease = host.target_lease;

pub const transport = "jlink-usb";
pub const operations_debug: []const model.Action = &.{ .registers, .halt, .step, .@"resume", .reset };
pub const operations_uart: []const model.Action = &.{ .registers, .halt, .step, .@"resume", .reset, .uart };
pub const operations_flash_debug: []const model.Action = &.{ .registers, .halt, .step, .@"resume", .flash, .reset };
pub const operations_flash_uart: []const model.Action = &.{
    .registers,
    .halt,
    .step,
    .@"resume",
    .flash,
    .reset,
    .uart,
};

pub const Probe = struct {
    io: std.Io,
    serial: u64,
    tool: commander.Tool,
    device: []const u8,
    cpuid: u32,
    uart_wired: bool = true,
    flash_enabled: bool = false,
    flash_base: u32 = 0,
    flash_size: u32 = 0,
    lease: ?target_lease.Lease = null,
    vcom: ?serial_port.Port = null,
    fence: target_lease.Fence = .{},
    uart: [2][64]u8 = undefined,

    pub fn provider(self: *Probe) model.Provider {
        return .{
            .context = self,
            .performFn = perform,
            .flashFn = flash,
            .claimFn = claim,
            .releaseFn = release,
        };
    }

    fn flash(context: *anyopaque, elf: []const u8, out: []u8) ![]const u8 {
        const self: *Probe = @ptrCast(@alignCast(context));
        const lease = self.lease orelse return error.NotReserved;
        try self.fence.admit(lease.token);
        if (!self.flash_enabled) return error.Unsupported;
        var text: [32768]u8 = undefined;
        const outcome = try commander.flashAndVerify(
            self.io,
            self.tool,
            self.serial,
            self.device,
            self.cpuid,
            self.flash_base,
            self.flash_size,
            elf,
            &text,
        );
        var digits: [20]u8 = undefined;
        var cpuid_buf: [12]u8 = undefined;
        const cpuid_hex = try std.fmt.bufPrint(&cpuid_buf, "0x{X:0>8}", .{outcome.identity.cpuid});
        var writer: std.Io.Writer = .fixed(out);
        try std.json.Stringify.value(.{
            .flashed = true,
            .verified = true,
            .serial = emu_list.format(outcome.identity.serial, &digits),
            .cpuid = cpuid_hex,
            .sha256 = &outcome.sha256,
            .segments = outcome.segments,
            .bytes = outcome.bytes,
            .lease = lease.token,
        }, .{}, &writer);
        return writer.buffered();
    }

    fn perform(context: *anyopaque, action: model.Action, out: []u8) ![]const u8 {
        const self: *Probe = @ptrCast(@alignCast(context));
        const lease = self.lease orelse return error.NotReserved;
        try self.fence.admit(lease.token);
        if (action == .uart) return self.readUart(lease.token, out);
        if (action == .reset and self.uart_wired) {
            self.closeVcom();
            self.vcom = serial_port.Port.openBySerial(self.io, self.serial) catch null;
        }
        var text: [16384]u8 = undefined;
        const outcome = try commander.operate(self.io, self.tool, self.serial, self.device, self.cpuid, action, &text);
        return formatOutcome(action, outcome, lease.token, out);
    }

    fn readUart(self: *Probe, token: u64, out: []u8) ![]const u8 {
        if (!self.uart_wired) return error.Unsupported;
        var text: [16384]u8 = undefined;
        const found = try commander.identify(self.io, self.tool, self.serial, self.device, &text);
        try identity.check(found, self.serial, self.cpuid);
        var vcom = self.vcom orelse ((try serial_port.Port.openBySerial(self.io, self.serial)) orelse
            return error.NoUart);
        self.vcom = null;
        defer vcom.close();
        var captured: [2048]u8 = undefined;
        const count = try vcom.readBounded(self.io, &captured, 1_000, 120, self.tool.cancel);
        var digits: [20]u8 = undefined;
        var cpuid_buf: [12]u8 = undefined;
        const cpuid_hex = try std.fmt.bufPrint(&cpuid_buf, "0x{X:0>8}", .{found.cpuid});
        var writer: std.Io.Writer = .fixed(out);
        try std.json.Stringify.value(.{
            .serial = emu_list.format(found.serial, &digits),
            .cpuid = cpuid_hex,
            .uart = vcom.name(),
            .bytes = count,
            .text = captured[0..count],
            .lease = token,
        }, .{}, &writer);
        return writer.buffered();
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
        self.closeVcom();
        if (self.lease) |*lease| lease.close(self.io);
        self.lease = null;
    }

    fn closeVcom(self: *Probe) void {
        if (self.vcom) |*vcom| vcom.close();
        self.vcom = null;
    }

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
        .flash, .uart => error.Unsupported,
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

pub fn hostSupportsUart() bool {
    return builtin.os.tag == .windows or builtin.os.tag == .linux;
}

pub fn operationsFor(has_flash: bool, has_uart: bool) []const model.Action {
    if (has_flash) return if (has_uart) operations_flash_uart else operations_flash_debug;
    return if (has_uart) operations_uart else operations_debug;
}

const FlashSpec = struct { enabled: bool, base: u32, size: u32 };

fn extractFlashSpec(fields: anytype) !FlashSpec {
    const Fields = @TypeOf(fields);
    const spec: FlashSpec = .{
        .enabled = if (@hasField(Fields, "flash_enabled")) fields.flash_enabled else false,
        .base = if (@hasField(Fields, "flash_base")) fields.flash_base else 0,
        .size = if (@hasField(Fields, "flash_size")) fields.flash_size else 0,
    };
    if (spec.enabled) {
        if (spec.size == 0) return error.InvalidEndpoint;
        _ = std.math.add(u32, spec.base, spec.size) catch return error.InvalidEndpoint;
    } else if (spec.base != 0 or spec.size != 0) {
        return error.InvalidEndpoint;
    }
    return spec;
}

pub fn configure(io: std.Io, target: model.Descriptor, fields: anytype) !Probe {
    const flash_spec = try extractFlashSpec(fields);
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
        .uart_wired = fields.uart_wired and hostSupportsUart(),
        .flash_enabled = flash_spec.enabled,
        .flash_base = flash_spec.base,
        .flash_size = flash_spec.size,
    };
}
