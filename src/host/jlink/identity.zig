//! Parses the identity and halted register lines a connected J-Link reports:
//! the probe serial, SCB CPUID (0xE000ED00), optional factory part-number
//! readback words (`PNR0..3`), PC, and SP.
const std = @import("std");

pub const cpuid_address: u32 = 0xE000ED00;

pub const Identity = struct {
    serial: u64,
    cpuid: u32,
    part: [16]u8 = @splat(0),
    part_len: u8 = 0,

    pub fn partSlice(self: *const Identity) []const u8 {
        return self.part[0..self.part_len];
    }
};

pub const Registers = struct {
    pc: u32,
    sp: u32,
};

pub fn parse(text: []const u8) !Identity {
    return parseWithPart(text, null);
}

const ScanState = struct {
    serial: ?u64 = null,
    cpuid: ?u32 = null,
    part: [16]u8 = @splat(0),
    part_found: bool = false,
};

fn absorbLine(state: *ScanState, line: []const u8, addr_prefix: []const u8) !void {
    if (try serialLine(line)) |value| {
        if (state.serial != null and state.serial.? != value) return error.BadIdentity;
        state.serial = value;
    } else if (try cpuidLine(line)) |value| {
        state.cpuid = value;
    } else if (addr_prefix.len != 0 and std.mem.startsWith(u8, line, addr_prefix)) {
        state.part = try decodePartWords(line[addr_prefix.len..]);
        state.part_found = true;
    }
}

pub fn parseWithPart(text: []const u8, part_addr: ?u32) !Identity {
    var state: ScanState = .{};
    var addr_prefix_buf: [16]u8 = undefined;
    const addr_prefix = if (part_addr) |addr|
        try std.fmt.bufPrint(&addr_prefix_buf, "{X:0>8} = ", .{addr})
    else
        "";

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        try absorbLine(&state, std.mem.trim(u8, raw, "\r "), addr_prefix);
    }
    var out: Identity = .{
        .serial = state.serial orelse return error.NoProbe,
        .cpuid = state.cpuid orelse return error.NoCore,
    };
    if (part_addr != null) {
        if (!state.part_found) return error.NoPartNumber;
        const trimmed = std.mem.trimEnd(u8, &state.part, " \x00\xff");
        @memcpy(out.part[0..trimmed.len], trimmed);
        out.part_len = @intCast(trimmed.len);
    }
    return out;
}

fn decodePartWords(rest: []const u8) ![16]u8 {
    var out: [16]u8 = @splat(0);
    var tokens = std.mem.tokenizeScalar(u8, rest, ' ');
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        const word_hex = tokens.next() orelse return error.BadIdentity;
        if (word_hex.len != 8) return error.BadIdentity;
        const word = std.fmt.parseInt(u32, word_hex, 16) catch return error.BadIdentity;
        std.mem.writeInt(u32, out[index * 4 ..][0..4], word, .little);
    }
    return out;
}

fn serialLine(line: []const u8) !?u64 {
    if (!std.mem.startsWith(u8, line, "S/N: ")) return null;
    return std.fmt.parseInt(u64, line["S/N: ".len..], 10) catch error.BadIdentity;
}

fn cpuidLine(line: []const u8) !?u32 {
    if (!std.mem.startsWith(u8, line, "E000ED00 = ")) return null;
    const word = std.mem.trim(u8, line["E000ED00 = ".len..], " ");
    if (word.len != 8) return error.BadIdentity;
    return std.fmt.parseInt(u32, word, 16) catch error.BadIdentity;
}

/// Extracts the last halted `PC = XXXXXXXX` and `SP(R13)= XXXXXXXX` lines.
pub fn parseRegisters(text: []const u8) !Registers {
    var pc: ?u32 = null;
    var sp: ?u32 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r ");
        if (hexAfter(line, "PC = ")) |value| pc = value;
        if (hexAfter(line, "SP(R13)= ")) |value| sp = value;
    }
    return .{ .pc = pc orelse return error.BadRegisters, .sp = sp orelse return error.BadRegisters };
}

fn hexAfter(line: []const u8, prefix: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = std.mem.trimStart(u8, line[prefix.len..], " ");
    if (rest.len < 8) return null;
    return std.fmt.parseInt(u32, rest[0..8], 16) catch null;
}

/// Refuses a probe that answered with another serial or a core other than the expected one.
pub fn check(found: Identity, serial: u64, cpuid: u32) !void {
    if (found.serial != serial) return error.WrongProbe;
    if (found.cpuid != cpuid) return error.WrongCore;
}

/// Refuses a probe whose factory part-number readback does not match `expected`.
pub fn checkWithPart(found: Identity, serial: u64, cpuid: u32, expected_part: []const u8) !void {
    try check(found, serial, cpuid);
    if (expected_part.len != 0 and !std.mem.eql(u8, found.partSlice(), expected_part)) {
        return error.WrongPart;
    }
}
