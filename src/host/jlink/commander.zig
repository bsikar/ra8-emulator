//! J-Link Commander invocations: list the attached probes, read one probe's
//! core and optional factory part-number identity, and run verified core debug,
//! flash/verify, and reset actions. Every call names the probe by USB serial,
//! never by list position, and runs within a bounded deadline with cancellation.
const std = @import("std");

const elf_image = @import("elf_image.zig");
const emu_list = @import("emu_list.zig");
const identity = @import("identity.zig");
const run_tool = @import("run.zig");
const targets = @import("../targets.zig");

pub const Tool = struct {
    /// J-Link Commander: `JLink.exe` on Windows, `JLinkExe` elsewhere.
    program: []const u8,
    /// Existing directory for the per-call command and staging files.
    scratch: []const u8,
    timeout_ms: u32 = 15_000,
    cancel: ?*const std.atomic.Value(bool) = null,
};

pub const PartSpec = struct {
    addr: u32 = 0,
    expected: []const u8 = "",
};

pub const Outcome = struct {
    identity: identity.Identity,
    registers: ?identity.Registers = null,
};

pub const FlashOutcome = struct {
    identity: identity.Identity,
    sha256: [64]u8,
    segments: usize,
    bytes: usize,
};

pub fn list(io: std.Io, tool: Tool, out: []emu_list.Probe, text: []u8) ![]emu_list.Probe {
    const result = try script(io, tool, "list", "ShowEmuList USB\nexit\n", &.{}, text);
    if (result.code != 0) return error.ProbeToolFailed;
    return emu_list.parse(result.output, out);
}

/// Connects over SWD to the probe with `serial` and reads CPUID without
/// halting or writing anything.
pub fn identify(io: std.Io, tool: Tool, serial: u64, device: []const u8, text: []u8) !identity.Identity {
    return identifyPart(io, tool, serial, device, null, text);
}

/// Connects over SWD to `serial` and reads CPUID plus optional 4-word factory
/// part-number registers at `part_addr` without halting or writing flash.
pub fn identifyPart(
    io: std.Io,
    tool: Tool,
    serial: u64,
    device: []const u8,
    part_addr: ?u32,
    text: []u8,
) !identity.Identity {
    var digits: [20]u8 = undefined;
    const usb = emu_list.format(serial, &digits);
    var cmd_buf: [96]u8 = undefined;
    const commands = if (part_addr) |addr|
        try std.fmt.bufPrint(&cmd_buf, "mem32 0xE000ED00 1\nmem32 0x{X:0>8} 4\nexit\n", .{addr})
    else
        "mem32 0xE000ED00 1\nexit\n";
    const extra = [_][]const u8{ "-USB", usb, "-Device", device, "-If", "SWD", "-Speed", "1000", "-AutoConnect", "1" };
    const result = try script(io, tool, usb, commands, &extra, text);
    if (result.code != 0) return error.ProbeToolFailed;
    return identity.parseWithPart(result.output, part_addr);
}

pub fn operate(
    io: std.Io,
    tool: Tool,
    serial: u64,
    device: []const u8,
    cpuid: u32,
    action: targets.Action,
    text: []u8,
) !Outcome {
    return operateProfile(io, tool, serial, device, cpuid, .{}, action, text);
}

/// Verifies `serial`, `cpuid`, and optional factory `part` first, then executes
/// `action` on that probe.
pub fn operateProfile(
    io: std.Io,
    tool: Tool,
    serial: u64,
    device: []const u8,
    cpuid: u32,
    part: PartSpec,
    action: targets.Action,
    text: []u8,
) !Outcome {
    const commands = switch (action) {
        .registers, .halt => "h\nregs\nexit\n",
        .step => "h\ns\nregs\nexit\n",
        .@"resume" => "g\nexit\n",
        .reset => "r\ng\nexit\n",
        .flash, .uart => return error.Unsupported,
    };
    const part_addr: ?u32 = if (part.addr != 0) part.addr else null;
    const found = try identifyPart(io, tool, serial, device, part_addr, text);
    try identity.checkWithPart(found, serial, cpuid, part.expected);
    var digits: [20]u8 = undefined;
    const usb = emu_list.format(serial, &digits);
    const extra = [_][]const u8{ "-USB", usb, "-Device", device, "-If", "SWD", "-Speed", "1000", "-AutoConnect", "1" };
    const result = try script(io, tool, usb, commands, &extra, text);
    if (result.code != 0) return error.ProbeToolFailed;
    if ((try parseSerial(result.output)) != serial) return error.WrongProbe;
    const need_regs = action == .registers or action == .halt or action == .step;
    return .{
        .identity = found,
        .registers = if (need_regs) try identity.parseRegisters(result.output) else null,
    };
}

pub fn flashAndVerify(
    io: std.Io,
    tool: Tool,
    serial: u64,
    device: []const u8,
    cpuid: u32,
    flash_base: u32,
    flash_size: u32,
    elf: []const u8,
    text: []u8,
) !FlashOutcome {
    return flashAndVerifyProfile(io, tool, serial, device, cpuid, .{}, flash_base, flash_size, elf, text);
}

/// Validates `elf` against `flash_base..flash_base+flash_size`, verifies
/// `serial`, `cpuid`, and optional factory `part` over SWD, programs via
/// `loadfile`, and verifies every loadable segment byte-for-byte via `verifybin`.
pub fn flashAndVerifyProfile(
    io: std.Io,
    tool: Tool,
    serial: u64,
    device: []const u8,
    cpuid: u32,
    part: PartSpec,
    flash_base: u32,
    flash_size: u32,
    elf: []const u8,
    text: []u8,
) !FlashOutcome {
    var seg_buf: [elf_image.max_segments]elf_image.Segment = undefined;
    const summary = try elf_image.parse(elf, &seg_buf);
    try elf_image.checkWindow(summary.segments, flash_base, flash_size);
    const part_addr: ?u32 = if (part.addr != 0) part.addr else null;
    const found = try identifyPart(io, tool, serial, device, part_addr, text);
    try identity.checkWithPart(found, serial, cpuid, part.expected);

    var digits: [20]u8 = undefined;
    const usb = emu_list.format(serial, &digits);
    const id = randomId(io);
    var dir = try std.Io.Dir.cwd().openDir(io, tool.scratch, .{});
    defer dir.close(io);
    defer cleanFlashStage(io, dir, usb, id, summary.segments.len);

    var cmd_buf: [8192]u8 = undefined;
    const commands = try stageFlashCommands(io, dir, tool.scratch, usb, id, elf, summary.segments, &cmd_buf);
    var flash_tool = tool;
    flash_tool.timeout_ms = @max(tool.timeout_ms, 45_000);
    const extra = [_][]const u8{ "-USB", usb, "-Device", device, "-If", "SWD", "-Speed", "1000", "-AutoConnect", "1" };
    const result = try script(io, flash_tool, usb, commands, &extra, text);
    if (result.code != 0 or hasFlashFailure(result.output)) return error.FlashFailed;
    if ((try parseSerial(result.output)) != serial) return error.WrongProbe;
    if (std.mem.count(u8, result.output, "Verify successful.") != summary.segments.len) return error.VerifyFailed;
    return .{
        .identity = found,
        .sha256 = elf_image.sha256Hex(elf),
        .segments = summary.segments.len,
        .bytes = summary.total_bytes,
    };
}

fn stageFlashCommands(
    io: std.Io,
    dir: std.Io.Dir,
    scratch: []const u8,
    usb: []const u8,
    id: u64,
    elf: []const u8,
    segments: []const elf_image.Segment,
    out: []u8,
) ![]const u8 {
    var elf_name_buf: [96]u8 = undefined;
    const elf_name = try std.fmt.bufPrint(&elf_name_buf, "flash-{s}-{x}.elf", .{ usb, id });
    try writeExclusive(io, dir, elf_name, elf);

    var writer: std.Io.Writer = .fixed(out);
    try writer.print("h\nloadfile \"{s}{c}{s}\"\n", .{ scratch, std.fs.path.sep, elf_name });
    for (segments, 0..) |seg, index| {
        var seg_name_buf: [96]u8 = undefined;
        const seg_name = try std.fmt.bufPrint(&seg_name_buf, "flash-{s}-{x}-s{d}.bin", .{ usb, id, index });
        try writeExclusive(io, dir, seg_name, seg.bytes);
        try writer.print("verifybin \"{s}{c}{s}\", 0x{X:0>8}\n", .{ scratch, std.fs.path.sep, seg_name, seg.paddr });
    }
    try writer.writeAll("exit\n");
    return writer.buffered();
}

fn cleanFlashStage(io: std.Io, dir: std.Io.Dir, usb: []const u8, id: u64, seg_count: usize) void {
    var name_buf: [128]u8 = undefined;
    const elf_name = std.fmt.bufPrint(&name_buf, "flash-{s}-{x}.elf", .{ usb, id }) catch return;
    deleteQuiet(io, dir, elf_name);
    for (0..seg_count) |index| {
        const seg_name = std.fmt.bufPrint(&name_buf, "flash-{s}-{x}-s{d}.bin", .{ usb, id, index }) catch return;
        deleteQuiet(io, dir, seg_name);
    }
}

fn deleteQuiet(io: std.Io, dir: std.Io.Dir, name: []const u8) void {
    dir.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("jlink stage cleanup ({s}): {s}\n", .{ name, @errorName(err) }),
    };
}

fn writeExclusive(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, name, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn hasFlashFailure(output: []const u8) bool {
    return std.mem.indexOf(u8, output, "Error while programming") != null or
        std.mem.indexOf(u8, output, "Verification failed") != null or
        std.mem.indexOf(u8, output, "Cannot download") != null or
        std.mem.indexOf(u8, output, "Failed to download") != null;
}

fn randomId(io: std.Io) u64 {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    return std.mem.readInt(u64, &nonce, .little);
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
    var name_buffer: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "jlink-{s}-{x}.jlink", .{ tag, randomId(io) });
    var dir = try std.Io.Dir.cwd().openDir(io, tool.scratch, .{});
    defer dir.close(io);
    try writeExclusive(io, dir, name, commands);
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
