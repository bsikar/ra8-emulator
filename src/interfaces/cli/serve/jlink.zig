//! Onboard J-Link targets: presence and the probe CDC interface come from a
//! USB scan keyed by the operator-pinned probe serial, ownership from a
//! host-wide lease, and every operation names the probe by serial and checks
//! the expected core and optional factory part number before acting.
const builtin = @import("builtin");
const std = @import("std");

const host = @import("ra8_host");

const board_profile = host.board_profile;
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
    .registers, .halt, .step, .@"resume", .flash, .reset, .uart,
};

pub const Probe = struct {
    io: std.Io,
    serial: u64,
    tool: commander.Tool,
    device: []const u8,
    cpuid: u32,
    part: commander.PartSpec = .{},
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
        const outcome = try commander.flashAndVerifyProfile(
            self.io,
            self.tool,
            self.serial,
            self.device,
            self.cpuid,
            self.part,
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
            .part = outcome.identity.partSlice(),
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
        const outcome = try commander.operateProfile(
            self.io,
            self.tool,
            self.serial,
            self.device,
            self.cpuid,
            self.part,
            action,
            &text,
        );
        return formatOutcome(action, outcome, lease.token, out);
    }

    fn readUart(self: *Probe, token: u64, out: []u8) ![]const u8 {
        if (!self.uart_wired) return error.Unsupported;
        var text: [16384]u8 = undefined;
        const part_addr: ?u32 = if (self.part.addr != 0) self.part.addr else null;
        const found = try commander.identifyPart(self.io, self.tool, self.serial, self.device, part_addr, &text);
        try identity.checkWithPart(found, self.serial, self.cpuid, self.part.expected);
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
            .part = found.partSlice(),
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

fn writeJson(out: []u8, value: anytype) ![]const u8 {
    var writer: std.Io.Writer = .fixed(out);
    try std.json.Stringify.value(value, .{}, &writer);
    return writer.buffered();
}

fn formatOutcome(action: model.Action, outcome: commander.Outcome, token: u64, out: []u8) ![]const u8 {
    var digits: [20]u8 = undefined;
    var cpuid_buf: [12]u8 = undefined;
    const s = emu_list.format(outcome.identity.serial, &digits);
    const c = try std.fmt.bufPrint(&cpuid_buf, "0x{X:0>8}", .{outcome.identity.cpuid});
    const p = outcome.identity.partSlice();
    const r = outcome.registers;
    return switch (action) {
        .registers => writeJson(
            out,
            .{ .serial = s, .cpuid = c, .part = p, .pc = r.?.pc, .sp = r.?.sp, .lease = token },
        ),
        .halt => writeJson(
            out,
            .{ .halted = true, .serial = s, .cpuid = c, .part = p, .pc = r.?.pc, .sp = r.?.sp, .lease = token },
        ),
        .step => writeJson(
            out,
            .{ .stepped = true, .serial = s, .cpuid = c, .part = p, .pc = r.?.pc, .sp = r.?.sp, .lease = token },
        ),
        .@"resume" => writeJson(out, .{ .resumed = true, .serial = s, .cpuid = c, .part = p, .lease = token }),
        .reset => writeJson(out, .{ .reset = true, .serial = s, .cpuid = c, .part = p, .lease = token }),
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

fn isPartIdentifier(text: []const u8) bool {
    if (text.len == 0 or text.len > 16) return false;
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

fn extractPartSpec(fields: anytype) !commander.PartSpec {
    const Fields = @TypeOf(fields);
    const spec: commander.PartSpec = .{
        .addr = if (@hasField(Fields, "part_addr")) fields.part_addr else 0,
        .expected = if (@hasField(Fields, "expected_part")) fields.expected_part else "",
    };
    if ((spec.addr == 0) != (spec.expected.len == 0)) return error.InvalidEndpoint;
    if (spec.expected.len != 0 and !isPartIdentifier(spec.expected)) return error.InvalidEndpoint;
    return spec;
}

fn hasManualIdentityOverrides(fields: anytype) bool {
    const Fields = @TypeOf(fields);
    const has_cpuid = if (@hasField(Fields, "cpuid")) fields.cpuid.len != 0 else false;
    const has_addr = if (@hasField(Fields, "part_addr")) fields.part_addr != 0 else false;
    const has_part = if (@hasField(Fields, "expected_part")) fields.expected_part.len != 0 else false;
    return has_cpuid or has_addr or has_part;
}

fn hasManualFlashOverrides(fields: anytype) bool {
    const Fields = @TypeOf(fields);
    const enabled = if (@hasField(Fields, "flash_enabled")) fields.flash_enabled else false;
    const has_base = if (@hasField(Fields, "flash_base")) fields.flash_base != 0 else false;
    const has_size = if (@hasField(Fields, "flash_size")) fields.flash_size != 0 else false;
    return enabled or has_base or has_size;
}

pub fn checkNoProfileOverrides(fields: anytype) !void {
    if (hasManualIdentityOverrides(fields) or hasManualFlashOverrides(fields)) {
        return error.InvalidEndpoint;
    }
}

pub const ResolvedProfile = struct {
    device: []const u8,
    cpuid: u32,
    part: commander.PartSpec,
    uart_wired: bool,
    flash_enabled: bool,
    flash_base: u32,
    flash_size: u32,
};

pub fn resolveProfile(board_id: []const u8) !ResolvedProfile {
    const prof = try board_profile.find(board_id);
    if (prof.availability != .arrived_qualified) return error.ProfileUnavailable;
    const swd = prof.swd orelse return error.ProfileUnavailable;
    const win = prof.flash_window orelse return error.ProfileUnavailable;
    const part: commander.PartSpec = if (swd.part_readback) |pr|
        .{ .addr = pr.address, .expected = pr.expected_ascii }
    else
        .{};
    return .{
        .device = swd.jlink_device,
        .cpuid = swd.cpuid,
        .part = part,
        .uart_wired = prof.uart_wired,
        .flash_enabled = true,
        .flash_base = win.base,
        .flash_size = win.size,
    };
}

pub fn configure(io: std.Io, target: model.Descriptor, fields: anytype) !Probe {
    const Fields = @TypeOf(fields);
    const use_prof = if (@hasField(Fields, "use_board_profile")) fields.use_board_profile else false;
    if (!std.mem.eql(u8, target.transport, transport)) return error.InvalidEndpoint;
    if (fields.program.len == 0 or fields.scratch.len == 0 or !std.fs.path.isAbsolute(fields.scratch)) {
        return error.InvalidEndpoint;
    }
    if (use_prof) return configureFromProfile(io, target, fields);
    const flash_spec = try extractFlashSpec(fields);
    const part_spec = try extractPartSpec(fields);
    if (fields.device.len == 0) return error.InvalidEndpoint;
    const hex = if (std.mem.startsWith(u8, fields.cpuid, "0x")) fields.cpuid[2..] else return error.InvalidEndpoint;
    return .{
        .io = io,
        .serial = try emu_list.serialOf(target.probe_serial),
        .tool = .{ .program = fields.program, .scratch = fields.scratch },
        .device = fields.device,
        .cpuid = std.fmt.parseInt(u32, hex, 16) catch return error.InvalidEndpoint,
        .part = part_spec,
        .uart_wired = fields.uart_wired and hostSupportsUart(),
        .flash_enabled = flash_spec.enabled,
        .flash_base = flash_spec.base,
        .flash_size = flash_spec.size,
    };
}

fn configureFromProfile(io: std.Io, target: model.Descriptor, fields: anytype) !Probe {
    try checkNoProfileOverrides(fields);
    const resolved = try resolveProfile(target.board_id);
    if (fields.device.len != 0 and !std.mem.eql(u8, fields.device, resolved.device)) return error.InvalidEndpoint;
    return .{
        .io = io,
        .serial = try emu_list.serialOf(target.probe_serial),
        .tool = .{ .program = fields.program, .scratch = fields.scratch },
        .device = resolved.device,
        .cpuid = resolved.cpuid,
        .part = resolved.part,
        .uart_wired = resolved.uart_wired and hostSupportsUart(),
        .flash_enabled = resolved.flash_enabled,
        .flash_base = resolved.flash_base,
        .flash_size = resolved.flash_size,
    };
}
