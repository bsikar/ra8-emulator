//! Parses the identity and halted register lines a connected J-Link reports:
//! the probe serial, SCB CPUID (0xE000ED00), PC, and SP.
const std = @import("std");

pub const cpuid_address: u32 = 0xE000ED00;

pub const Identity = struct {
    serial: u64,
    cpuid: u32,
};

pub const Registers = struct {
    pc: u32,
    sp: u32,
};

pub fn parse(text: []const u8) !Identity {
    var serial: ?u64 = null;
    var cpuid: ?u32 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r ");
        if (try serialLine(line)) |value| {
            if (serial != null and serial.? != value) return error.BadIdentity;
            serial = value;
        } else if (try cpuidLine(line)) |value| {
            cpuid = value;
        }
    }
    return .{ .serial = serial orelse return error.NoProbe, .cpuid = cpuid orelse return error.NoCore };
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
