//! Normalized digest and byte-level comparison for the `storage` snapshot
//! section (option MRAM, xSPI controller and OSPI NOR flash).
//!
//! Option MRAM OTP cells and xSPI registers hold post-load hardware state
//! and compare as written. OSPI NOR sectors at `0x8000_0000` may hold XIP
//! read-only or load-copy ELF segments alongside post-load flash programming,
//! so each sector's bytes are normalized with `state_memory.Mask`.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const fields = @import("ra8_board").snapshot.run.fields;
const mram_mod = @import("ra8_chip").periph.mram;
const mram_snap = mram_mod.snapshot;
const xspi_mod = @import("ra8_chip").periph.xspi;
const nor_snap = @import("ra8_components").nor_flash.snapshot;
const memory = @import("state_memory.zig");

pub const sector_len: u32 = memory.page;
pub const Error = fields.Error || memory.Error;

pub const Parsed = struct {
    prefix: []const u8,
    nor: nor_snap.Staged,
};

const controller_wiring = .{ "part", "octa" };

pub fn parse(payload: []const u8) Error!Parsed {
    var cursor: fields.Cursor = .{ .bytes = payload };
    var dummy_mram: mram_mod.Mram = undefined;
    dummy_mram.otp = undefined;
    dummy_mram.memory = null;
    const staged_mram = try mram_snap.read(&cursor, &dummy_mram);
    if (!staged_mram.fits()) return Error.BadValue;
    var dummy_ctrl: xspi_mod.Xspi = undefined;
    try fields.readOver(&cursor, &dummy_ctrl, controller_wiring);
    const prefix = payload[0..cursor.at];
    const nor = try nor_snap.read(&cursor);
    if (!cursor.done() or nor.capacity % sector_len != 0) return Error.BadValue;
    return .{ .prefix = prefix, .nor = nor };
}

fn sectorAt(nor: nor_snap.Staged, index: u32) ?[]const u8 {
    var lo: u32 = 0;
    var hi: u32 = nor.sectors.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const num = nor.sectors.number(mid);
        if (num == index) return nor.sectors.value(mid);
        if (num < index) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn collectImageSectors(image: elf.Image, capacity: u32, list: *std.ArrayListUnmanaged(u32), buf: []u32) void {
    const end_limit: u64 = @as(u64, memory.ospi_base) + capacity;
    var i: u16 = 0;
    while (i < image.segmentCount()) : (i += 1) {
        const seg = image.loadSegment(i) orelse continue;
        const s0: u64 = seg.paddr;
        const s1: u64 = s0 + seg.bytes.len;
        if (s1 <= memory.ospi_base or s0 >= end_limit) continue;
        const lo_addr: u32 = @intCast(@max(s0, memory.ospi_base));
        const hi_addr: u64 = @min(s1, end_limit);
        var sec: u32 = (lo_addr - memory.ospi_base) / sector_len;
        const sec_end: u32 = @intCast((hi_addr - memory.ospi_base + sector_len - 1) / sector_len);
        while (sec < sec_end and list.items.len < buf.len) : (sec += 1) {
            list.appendAssumeCapacity(sec);
        }
    }
}

/// Sorted unique candidate sectors: dirty sectors plus OSPI sectors covered
/// by `mask.a` or `mask.b`. Falls back to scanning all sectors if `buf` fills.
fn candidateSectors(a: nor_snap.Staged, b: ?nor_snap.Staged, mask: memory.Mask, buf: []u32) ?[]const u32 {
    const needed: u64 = @as(u64, a.sectors.count) + (if (b) |nb| nb.sectors.count else 0);
    if (needed > buf.len) return null;
    var list = std.ArrayListUnmanaged(u32).initBuffer(buf);
    var i: u32 = 0;
    while (i < a.sectors.count) : (i += 1) list.appendAssumeCapacity(a.sectors.number(i));
    if (b) |nb| {
        var j: u32 = 0;
        while (j < nb.sectors.count) : (j += 1) list.appendAssumeCapacity(nb.sectors.number(j));
    }
    if (mask.a) |img| collectImageSectors(img, a.capacity, &list, buf);
    if (mask.b) |img| collectImageSectors(img, a.capacity, &list, buf);
    if (list.items.len == buf.len and (mask.a != null or mask.b != null)) return null;
    std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    var out: usize = 0;
    for (list.items) |sec| {
        if (sec >= a.capacity / sector_len) continue;
        if (out == 0 or list.items[out - 1] != sec) {
            list.items[out] = sec;
            out += 1;
        }
    }
    return list.items[0..out];
}

fn hashSector(hasher: *std.crypto.hash.Blake3, parsed: Parsed, mask: memory.Mask, sec: u32) void {
    const in_sec = sectorAt(parsed.nor, sec);
    const base = memory.ospi_base +% sec * sector_len;
    if (in_sec == null) {
        if (mask.a == null or !memory.overlapsLoaded(mask.a.?, base, sector_len)) return;
    }
    var flags: [sector_len / 8]u8 = @splat(0);
    var bytes: [sector_len]u8 = undefined;
    var any = false;
    for (0..sector_len) |i| {
        const addr = base +% @as(u32, @intCast(i));
        const raw: u8 = if (in_sec) |p| p[i] else 0xFF;
        const c = mask.cell(addr, raw);
        const norm: u8 = if (mask.skips(addr)) c.byte else c.byte ^ 0xFF;
        bytes[i] = norm;
        if (c.mutated) flags[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        any = any or c.mutated or norm != 0;
    }
    if (!any) return;
    hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, sec)));
    hasher.update(&flags);
    hasher.update(&bytes);
}

pub fn hash(hasher: *std.crypto.hash.Blake3, parsed: Parsed, mask: memory.Mask) void {
    hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(parsed.prefix.len))));
    hasher.update(parsed.prefix);
    hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, parsed.nor.capacity)));
    var buf: [2048]u32 = undefined;
    if (candidateSectors(parsed.nor, null, mask, &buf)) |sectors| {
        for (sectors) |sec| hashSector(hasher, parsed, mask, sec);
    } else {
        const total = parsed.nor.capacity / sector_len;
        var sec: u32 = 0;
        while (sec < total) : (sec += 1) hashSector(hasher, parsed, mask, sec);
    }
}

pub const Diff = union(enum) {
    none,
    section,
    memory: memory.Spot,
};

fn diffSector(a: Parsed, b: Parsed, mask: memory.Mask, sec: u32) ?memory.Spot {
    const in_a = sectorAt(a.nor, sec);
    const in_b = sectorAt(b.nor, sec);
    const base = memory.ospi_base +% sec * sector_len;
    const peer = mask.flipped();
    for (0..sector_len) |i| {
        const addr = base +% @as(u32, @intCast(i));
        const raw_a: u8 = if (in_a) |p| p[i] else 0xFF;
        const raw_b: u8 = if (in_b) |p| p[i] else 0xFF;
        if (!mask.cell(addr, raw_a).eql(peer.cell(addr, raw_b))) {
            return .{ .address = addr, .expected = raw_a, .actual = raw_b };
        }
    }
    return null;
}

pub fn compare(expected: Parsed, actual: Parsed, mask: memory.Mask) Diff {
    if (!std.mem.eql(u8, expected.prefix, actual.prefix)) return .section;
    if (expected.nor.capacity != actual.nor.capacity) return .section;
    var buf: [2048]u32 = undefined;
    if (candidateSectors(expected.nor, actual.nor, mask, &buf)) |sectors| {
        for (sectors) |sec| if (diffSector(expected, actual, mask, sec)) |spot| return .{ .memory = spot };
    } else {
        const total = expected.nor.capacity / sector_len;
        var sec: u32 = 0;
        while (sec < total) : (sec += 1) {
            if (diffSector(expected, actual, mask, sec)) |spot| return .{ .memory = spot };
        }
    }
    return .none;
}
