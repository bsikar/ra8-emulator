//! macOS resolves a J-Link probe's CDC callout path via IORegistry (`idVendor` + serial).
const std = @import("std");

const emu_list = @import("../emu_list.zig");
const run_tool = @import("../run.zig");
const serial_macos = @import("../serial/macos.zig");

pub const segger_vendor_id: u16 = 4966;

const ioreg_argv = [_][]const u8{
    "/usr/sbin/ioreg", "-r", "-c", "IOUSBHostInterface", "-l", "-w", "0",
};

/// Resolves `/dev/cu.usbmodem*` for `serial` when SEGGER CDC exists on macOS.
pub fn find(io: std.Io, serial: u64, out: []u8) !?[]const u8 {
    if (!try hasCalloutCandidate(io)) return null;
    const text = try std.heap.page_allocator.alloc(u8, 131072);
    defer std.heap.page_allocator.free(text);
    const outcome = run_tool.run(io, &ioreg_argv, text, 5_000) catch return error.DeviceListFailed;
    if (outcome.code != 0) return error.DeviceListFailed;
    return parseIoreg(outcome.output, serial, out);
}

fn hasCalloutCandidate(io: std.Io) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, "/dev", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "cu.usbmodem")) return true;
    }
    return false;
}

/// Parses `ioreg -r -c IOUSBHostInterface -l -w 0` text, matching SEGGER CDC callouts by serial.
pub fn parseIoreg(text: []const u8, serial: u64, out: []u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    var at: usize = 0;
    while (nextRootBlock(text, &at)) |block| {
        if (try matchBlock(block, serial)) |path| {
            if (found != null) return error.DuplicateSerial;
            found = try std.fmt.bufPrint(out, "{s}", .{path});
        }
    }
    return found;
}

fn nextRootBlock(text: []const u8, at: *usize) ?[]const u8 {
    while (at.* < text.len) {
        if (std.mem.startsWith(u8, text[at.*..], "+-o ")) {
            const start = at.*;
            const end = if (std.mem.indexOf(u8, text[start + 4 ..], "\n+-o ")) |rel|
                start + 4 + rel + 1
            else
                text.len;
            at.* = end;
            return text[start..end];
        }
        const nl = std.mem.indexOfScalarPos(u8, text, at.*, '\n') orelse break;
        at.* = nl + 1;
    }
    return null;
}

fn matchBlock(block: []const u8, serial: u64) !?[]const u8 {
    var vendor_ok = false;
    var serial_ok = false;
    var callout: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r\t |");
        if (std.mem.eql(u8, line, "\"idVendor\" = 4966")) {
            vendor_ok = true;
        } else if (matchesSerialLine(line, serial)) {
            serial_ok = true;
        } else if (extractQuoted(line, "\"IOCalloutDevice\" = \"")) |dev| {
            callout = dev;
        }
    }
    if (!vendor_ok or !serial_ok) return null;
    const path = callout orelse return null;
    if (!serial_macos.allowedCalloutPath(path)) return error.BadPortName;
    return path;
}

fn matchesSerialLine(line: []const u8, serial: u64) bool {
    const raw_sn = extractQuoted(line, "\"USB Serial Number\" = \"") orelse return false;
    const parsed = emu_list.serialOf(raw_sn) catch return false;
    return parsed == serial;
}

fn extractQuoted(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (end != rest.len - 1) return null;
    return rest[0..end];
}
