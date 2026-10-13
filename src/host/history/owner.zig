//! A session directory's `owner` file: the marker that says the directory
//! is a history session, and who made it. Only the host name bears on a
//! deletion, and only to rule a directory out. Liveness is the OS lock on
//! `owner.lock`, never anything written here.
const std = @import("std");
const layout = @import("layout.zig");
const machine = @import("machine.zig");
const metadata = @import("metadata.zig");

pub const max_bytes = 2048;

pub const Record = struct {
    host: []const u8,
    pid: u64 = 0,
    boot: []const u8 = "",
    /// Seconds since the epoch, for display.
    started_s: i64 = 0,
};

/// Room for the strings of this process's own record.
pub const Self = struct {
    host: [machine.limits.host]u8 = undefined,
    boot: [machine.limits.boot]u8 = undefined,

    pub fn record(self: *Self, io: std.Io) Record {
        return .{
            .host = machine.hostName(&self.host),
            .pid = machine.processId(),
            .boot = machine.bootId(io, &self.boot),
            .started_s = std.Io.Timestamp.now(io, .real).toSeconds(),
        };
    }
};

pub fn write(io: std.Io, dir: std.Io.Dir, record: Record) !void {
    if (!lineSafe(record.host) or !lineSafe(record.boot) or record.host.len == 0) return error.BadOwner;
    var buffer: [max_bytes]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, layout.owner_magic ++ "\nhost={s}\npid={d}\nboot={s}\nstarted={d}\n", .{ record.host, record.pid, record.boot, record.started_s });
    try metadata.ensure(io, dir, layout.files.owner, text);
}

/// The record of the session directory `dir`, its strings in `buffer`.
/// `Unmarked` when the directory has no owner file or not one of ours.
pub fn read(io: std.Io, dir: std.Io.Dir, buffer: *[max_bytes]u8) error{Unmarked}!Record {
    const text = metadata.read(io, dir, layout.files.owner, buffer) catch return error.Unmarked;
    return parse(text);
}

/// Version 1 has exactly these four ordered fields and a final newline.
/// Reject duplicates, unknown/truncated fields, controls and invalid numbers.
/// PID and start remain display data, never liveness evidence.
pub fn parse(text: []const u8) error{Unmarked}!Record {
    if (std.mem.indexOfAny(u8, text, "\r\x00") != null) return error.Unmarked;
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", layout.owner_magic)) return error.Unmarked;
    const host = try field(lines.next(), "host=");
    const pid = try field(lines.next(), "pid=");
    const boot = try field(lines.next(), "boot=");
    if (!lineSafe(host) or !lineSafe(boot)) return error.Unmarked;
    const started = try field(lines.next(), "started=");
    if (host.len == 0 or !std.mem.eql(u8, lines.next() orelse return error.Unmarked, "")) return error.Unmarked;
    if (lines.next() != null or !decimal(pid, false) or !decimal(started, true)) return error.Unmarked;
    return .{
        .host = host,
        .pid = std.fmt.parseInt(u64, pid, 10) catch return error.Unmarked,
        .boot = boot,
        .started_s = std.fmt.parseInt(i64, started, 10) catch return error.Unmarked,
    };
}

fn field(line: ?[]const u8, prefix: []const u8) error{Unmarked}![]const u8 {
    const text = line orelse return error.Unmarked;
    if (!std.mem.startsWith(u8, text, prefix)) return error.Unmarked;
    return text[prefix.len..];
}

fn decimal(text: []const u8, signed: bool) bool {
    const digits = if (signed and std.mem.startsWith(u8, text, "-")) text[1..] else text;
    if (digits.len == 0) return false;
    for (digits) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

fn lineSafe(text: []const u8) bool {
    for (text) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}
