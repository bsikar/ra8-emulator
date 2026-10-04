//! FAT directory entries for the image builder (RA8EMU-563): the 32-byte
//! short entry, the long-name (LFN) entries in front of it, and the 8.3
//! short name a long name is given. Every entry carries one fixed timestamp
//! so an image is the same bytes whenever it is built.
const std = @import("std");

pub const bytes: usize = 32;
pub const Entry = [bytes]u8;

pub const attr = struct {
    pub const volume: u8 = 0x08;
    pub const directory: u8 = 0x10;
    pub const archive: u8 = 0x20;
    pub const long_name: u8 = 0x0F;
};

/// 2026-01-01 00:00:00, the one time every entry states.
pub const stamp = struct {
    pub const date: u16 = ((2026 - 1980) << 9) | (1 << 5) | 1;
    pub const time: u16 = 0;
};

/// UTF-16 units one long-name entry carries, and the most a name may use.
pub const lfn_units: usize = 13;
pub const max_units: usize = 255;
/// The last tail a directory can hand out: "~999999" leaves one base char.
pub const max_tail: u32 = 999_999;

pub const Error = error{ BadName, NameTooLong };

/// Entries `name` takes: its long-name entries, if any, plus the short one.
pub fn slots(name: []const u8) Error!usize {
    if (isShort(name)) return 1;
    const units = std.unicode.calcUtf16LeLen(name) catch return error.BadName;
    if (units == 0 or units > max_units) return error.NameTooLong;
    return 1 + (units + lfn_units - 1) / lfn_units;
}

/// Whether `name` is already an upper-case 8.3 name, so no LFN is needed.
/// A '~' always takes the long path, so a generated tail can never collide.
pub fn isShort(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '~') != null) return false;
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    const base = name[0..dot];
    const ext = if (dot < name.len) name[dot + 1 ..] else "";
    if (base.len == 0 or base.len > 8 or ext.len > 3) return false;
    if (dot < name.len and ext.len == 0) return false;
    for (base) |c| if (!legal(c)) return false;
    for (ext) |c| if (!legal(c)) return false;
    return true;
}

/// The 11-byte short name: the name itself when it is 8.3, else BASE~N.EXT
/// with N the long name's place among its directory's long names.
pub fn shortName(name: []const u8, index: u32) [11]u8 {
    var out = [_]u8{' '} ** 11;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const split = if (dot) |d| (if (d == 0) name.len else d) else name.len;
    const ext = if (split < name.len) name[split + 1 ..] else "";
    if (isShort(name)) {
        @memcpy(out[0..split], name[0..split]);
        @memcpy(out[8..][0..ext.len], ext);
        return out;
    }
    var tail_buf: [8]u8 = undefined;
    const tail = std.fmt.bufPrint(&tail_buf, "~{d}", .{index}) catch unreachable;
    var n = copyLegal(out[0 .. 8 - tail.len], name[0..split]);
    if (n == 0) {
        out[0] = '_';
        n = 1;
    }
    @memcpy(out[n..][0..tail.len], tail);
    _ = copyLegal(out[8..11], ext);
    return out;
}

/// The short entry: name, attribute, first cluster, size and the stamp.
pub fn short(name11: [11]u8, attribute: u8, cluster: u32, size: u32) Entry {
    var e = [_]u8{0} ** bytes;
    @memcpy(e[0..11], &name11);
    e[11] = attribute;
    put16(&e, 14, stamp.time);
    put16(&e, 16, stamp.date);
    put16(&e, 18, stamp.date);
    put16(&e, 20, @truncate(cluster >> 16));
    put16(&e, 22, stamp.time);
    put16(&e, 24, stamp.date);
    put16(&e, 26, @truncate(cluster));
    std.mem.writeInt(u32, e[28..32], size, .little);
    return e;
}

/// Write `name`'s entries into `out` (long ones first, last chunk first)
/// and return how many slots they took.
pub fn put(out: []Entry, name: []const u8, index: u32, attribute: u8, cluster: u32, size: u32) Error!usize {
    const name11 = shortName(name, index);
    const count = try slots(name);
    if (count > 1) {
        var units: [max_units]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&units, name) catch return error.BadName;
        const sum = checksum(&name11);
        const chunks = count - 1;
        for (0..chunks) |slot| {
            const chunk = chunks - 1 - slot;
            out[slot] = longEntry(units[0..len], chunk, chunk + 1 == chunks, sum);
        }
    }
    out[count - 1] = short(name11, attribute, cluster, size);
    return count;
}

/// The checksum every long entry carries of its short name.
pub fn checksum(name11: *const [11]u8) u8 {
    var sum: u8 = 0;
    for (name11) |c| sum = ((sum & 1) << 7) +% (sum >> 1) +% c;
    return sum;
}

fn longEntry(units: []const u16, chunk: usize, last: bool, sum: u8) Entry {
    var e = [_]u8{0} ** bytes;
    e[0] = @as(u8, @intCast(chunk + 1)) | (if (last) @as(u8, 0x40) else 0);
    e[11] = attr.long_name;
    e[13] = sum;
    for (0..lfn_units) |k| {
        const at = chunk * lfn_units + k;
        const unit: u16 = if (at < units.len) units[at] else if (at == units.len) 0 else 0xFFFF;
        const offset: usize = if (k < 5) 1 + 2 * k else if (k < 11) 14 + 2 * (k - 5) else 28 + 2 * (k - 11);
        put16(&e, offset, unit);
    }
    return e;
}

fn copyLegal(out: []u8, source: []const u8) usize {
    var n: usize = 0;
    for (source) |c| {
        if (n == out.len) break;
        const up = std.ascii.toUpper(c);
        if (!legal(up)) continue;
        out[n] = up;
        n += 1;
    }
    return n;
}

fn legal(c: u8) bool {
    if (std.ascii.isUpper(c) or std.ascii.isDigit(c)) return true;
    return std.mem.indexOfScalar(u8, "!#$%&'()-@^_`{}~", c) != null;
}

fn put16(e: *Entry, offset: usize, value: u16) void {
    std.mem.writeInt(u16, e[offset..][0..2], value, .little);
}
