//! J-Link Commander invocations: list the attached probes, read one probe's
//! core identity, and run verified core debug/reset actions. Every call names
//! the probe by USB serial, never by list position, and runs within a deadline.
const std = @import("std");

const emu_list = @import("emu_list.zig");
const identity = @import("identity.zig");
const run_tool = @import("run.zig");
const targets = @import("../targets.zig");

pub const Tool = struct {
    /// J-Link Commander: `JLink.exe` on Windows, `JLinkExe` elsewhere.
    program: []const u8,
    /// Existing directory for the per-call command files.
    scratch: []const u8,
    timeout_ms: u32 = 15_000,
    cancel: ?*const std.atomic.Value(bool) = null,
};

pub const Outcome = struct {
    identity: identity.Identity,
    registers: ?identity.Registers = null,
};

pub fn list(io: std.Io, tool: Tool, out: []emu_list.Probe, text: []u8) ![]emu_list.Probe {
    const result = try script(io, tool, "list", "ShowEmuList USB\nexit\n", &.{}, text);
    if (result.code != 0) return error.ProbeToolFailed;
    return emu_list.parse(result.output, out);
}

/// Connects over SWD to the probe with `serial` and reads CPUID without
/// halting or writing anything.
pub fn identify(io: std.Io, tool: Tool, serial: u64, device: []const u8, text: []u8) !identity.Identity {
    var digits: [20]u8 = undefined;
    const usb = emu_list.format(serial, &digits);
    const extra = [_][]const u8{ "-USB", usb, "-Device", device, "-If", "SWD", "-Speed", "1000", "-AutoConnect", "1" };
    const result = try script(io, tool, usb, "mem32 0xE000ED00 1\nexit\n", &extra, text);
    if (result.code != 0) return error.ProbeToolFailed;
    return identity.parse(result.output);
}

/// Verifies `serial` and `cpuid` first, then executes `action` on that probe.
/// The check and the action are two Commander sessions, each selected by
/// `-USB serial`. Commander scripts cannot branch on a read value, so the
/// serial is checked again only after the action session has run.
pub fn operate(
    io: std.Io,
    tool: Tool,
    serial: u64,
    device: []const u8,
    cpuid: u32,
    action: targets.Action,
    text: []u8,
) !Outcome {
    const commands = switch (action) {
        .registers => "h\nregs\nexit\n",
        .halt => "h\nexit\n",
        .step => "h\ns\nregs\nexit\n",
        .@"resume" => "g\nexit\n",
        .reset => "r\ng\nexit\n",
        .flash, .uart => return error.Unsupported,
    };
    const found = try identify(io, tool, serial, device, text);
    try identity.check(found, serial, cpuid);
    var digits: [20]u8 = undefined;
    const usb = emu_list.format(serial, &digits);
    const extra = [_][]const u8{ "-USB", usb, "-Device", device, "-If", "SWD", "-Speed", "1000", "-AutoConnect", "1" };
    const result = try script(io, tool, usb, commands, &extra, text);
    if (result.code != 0) return error.ProbeToolFailed;
    const checked = try parseSerial(result.output);
    if (checked != serial) return error.WrongProbe;
    const need_regs = action == .registers or action == .halt or action == .step;
    return .{
        .identity = found,
        .registers = if (need_regs) try identity.parseRegisters(result.output) else null,
    };
}

fn parseSerial(text: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r ");
        if (std.mem.startsWith(u8, line, "S/N: ")) {
            return std.fmt.parseInt(u64, line["S/N: ".len..], 10) catch return error.BadIdentity;
        }
    }
    return error.NoProbe;
}

fn script(
    io: std.Io,
    tool: Tool,
    tag: []const u8,
    commands: []const u8,
    extra: []const []const u8,
    text: []u8,
) !run_tool.Result {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    var name_buffer: [96]u8 = undefined;
    const id = std.mem.readInt(u64, &nonce, .little);
    const name = try std.fmt.bufPrint(&name_buffer, "jlink-{s}-{x}.jlink", .{ tag, id });
    var dir = try std.Io.Dir.cwd().openDir(io, tool.scratch, .{});
    defer dir.close(io);
    {
        const file = try dir.createFile(io, name, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, commands);
    }
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}{c}{s}", .{ tool.scratch, std.fs.path.sep, name });
    var argv: [24][]const u8 = undefined;
    const head = [_][]const u8{ tool.program, "-NoGui", "1", "-ExitOnError", "1" };
    @memcpy(argv[0..head.len], &head);
    @memcpy(argv[head.len..][0..extra.len], extra);
    const tail = head.len + extra.len;
    argv[tail] = "-CommandFile";
    argv[tail + 1] = path;
    const outcome = run_tool.runWithCancel(io, argv[0 .. tail + 2], text, tool.timeout_ms, tool.cancel);
    dir.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return outcome;
}
