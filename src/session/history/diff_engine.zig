//! State diff engine (Slice 23.5): computes structured diffs between two
//! execution positions, manifests, or machine state snapshots.
//!
//! Diffs CPU0/CPU1 architectural registers, 4 KiB paged memory spaces,
//! and peripheral state blocks.
const std = @import("std");
const manifest_mod = @import("manifest.zig");
const ObjectId = @import("object_id.zig").ObjectId;
const position_mod = @import("position.zig");
const Position = position_mod.Position;
const board_snap = @import("ra8_board").snapshot.run;
const file = board_snap.file;
const fields = board_snap.fields;
const regs_mod = @import("ra8_chip").core.cpu.regs;

pub const RegDiff = struct {
    name: []const u8,
    val_a: u32,
    val_b: u32,
};

pub const PageDiff = struct {
    space: manifest_mod.SpaceId,
    page_index: u32,
    address: u32,
    obj_a: ?ObjectId = null,
    obj_b: ?ObjectId = null,
};

pub const PeriphDelta = struct {
    unit: []const u8,
    kind: file.Kind,
    offset: u32,
    old_val: u32,
    new_val: u32,
    changed_bytes: u32,
};

pub const DiffResult = struct {
    pos_a: Position,
    pos_b: Position,
    cpu0_regs: []RegDiff = &.{},
    cpu1_regs: []RegDiff = &.{},
    pages: []PageDiff = &.{},
    periphs: []PeriphDelta = &.{},

    pub fn deinit(self: *DiffResult, allocator: std.mem.Allocator) void {
        allocator.free(self.cpu0_regs);
        allocator.free(self.cpu1_regs);
        allocator.free(self.pages);
        allocator.free(self.periphs);
        self.* = undefined;
    }
};

pub fn spaceBaseAddress(space: manifest_mod.SpaceId) ?u32 {
    return switch (space) {
        .cpu0_mram => 0x0000_0000,
        .cpu0_dtcm => 0x2000_0000,
        .cpu0_sram => 0x2200_0000,
        .cpu0_sdram => 0x6000_0000,
        .cpu0_ppb => 0xE000_0000,
        .cpu1_mram => 0x0100_0000,
        .cpu1_dtcm => 0x3000_0000,
        .cpu1_ppb => 0xE000_0000,
        .nor_flash => 0x7000_0000,
        else => null,
    };
}

const reg_names = [_][]const u8{
    "r0",   "r1",      "r2",  "r3",  "r4",      "r5",      "r6", "r7",
    "r8",   "r9",      "r10", "r11", "r12",     "sp",      "lr", "pc",
    "xpsr", "control", "msp", "psp", "primask", "basepri",
};

pub const CoreRegs = struct {
    values: [reg_names.len]u32 = @splat(0),
    present: bool = false,

    pub fn fromRegs(r: *const regs_mod.Regs) CoreRegs {
        var cr = CoreRegs{ .present = true };
        for (0..13) |i| cr.values[i] = r.low[i];
        cr.values[13] = r.sp();
        cr.values[14] = r.lr;
        cr.values[15] = r.pc;
        cr.values[16] = r.xpsr;
        cr.values[17] = r.control;
        cr.values[18] = r.msp;
        cr.values[19] = r.psp;
        cr.values[20] = r.primask;
        cr.values[21] = r.basepri;
        return cr;
    }
};

pub fn decodeCoreRegs(bytes: []const u8, target_core: u8) ?CoreRegs {
    var reader = file.Reader.open(bytes) catch return null;
    while (reader.next() catch null) |sec| {
        if (sec.kind != .cpu) continue;
        var cursor: fields.Cursor = .{ .bytes = sec.payload };
        const core = fields.read(u8, &cursor) catch continue;
        if (core != target_core) continue;
        const regs = fields.read(regs_mod.Regs, &cursor) catch continue;
        return CoreRegs.fromRegs(&regs);
    }
    return null;
}

pub fn diffCoreRegs(
    allocator: std.mem.Allocator,
    a: ?CoreRegs,
    b: ?CoreRegs,
) ![]RegDiff {
    if (a == null and b == null) return &.{};
    const reg_a = a orelse CoreRegs{};
    const reg_b = b orelse CoreRegs{};
    var list: std.ArrayList(RegDiff) = .empty;
    defer list.deinit(allocator);

    for (reg_names, 0..) |name, i| {
        const va = reg_a.values[i];
        const vb = reg_b.values[i];
        if (va != vb or (a == null) != (b == null)) {
            try list.append(allocator, .{ .name = name, .val_a = va, .val_b = vb });
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn diffPages(
    allocator: std.mem.Allocator,
    current: ?*const manifest_mod.Manifest,
    target: *const manifest_mod.Manifest,
) ![]PageDiff {
    var list: std.ArrayList(PageDiff) = .empty;
    defer list.deinit(allocator);

    if (current) |cur| {
        var c_idx: usize = 0;
        var t_idx: usize = 0;
        while (t_idx < target.pages.len) {
            const tp = target.pages[t_idx];
            if (c_idx >= cur.pages.len) {
                try appendPage(&list, allocator, tp, null, tp.object);
                t_idx += 1;
                continue;
            }
            const cp = cur.pages[c_idx];
            switch (manifest_mod.pageOrder(tp, cp)) {
                .lt => {
                    try appendPage(&list, allocator, tp, null, tp.object);
                    t_idx += 1;
                },
                .gt => {
                    try appendPage(&list, allocator, cp, cp.object, null);
                    c_idx += 1;
                },
                .eq => {
                    if (!tp.object.eql(cp.object)) {
                        try appendPage(&list, allocator, tp, cp.object, tp.object);
                    }
                    t_idx += 1;
                    c_idx += 1;
                },
            }
        }
        while (c_idx < cur.pages.len) : (c_idx += 1) {
            const cp = cur.pages[c_idx];
            try appendPage(&list, allocator, cp, cp.object, null);
        }
    } else {
        for (target.pages) |tp| {
            try appendPage(&list, allocator, tp, null, tp.object);
        }
    }
    return list.toOwnedSlice(allocator);
}

fn appendPage(
    list: *std.ArrayList(PageDiff),
    allocator: std.mem.Allocator,
    pref: manifest_mod.PageRef,
    obj_a: ?ObjectId,
    obj_b: ?ObjectId,
) !void {
    const base = spaceBaseAddress(pref.space) orelse 0;
    const addr = base + pref.page_index * 4096;
    try list.append(allocator, .{
        .space = pref.space,
        .page_index = pref.page_index,
        .address = addr,
        .obj_a = obj_a,
        .obj_b = obj_b,
    });
}

fn findSection(bytes: []const u8, kind: file.Kind) ?[]const u8 {
    var reader = file.Reader.open(bytes) catch return null;
    while (reader.next() catch null) |sec| {
        if (sec.kind == kind) return sec.payload;
    }
    return null;
}

pub fn diffPeripherals(
    allocator: std.mem.Allocator,
    snap_a: ?[]const u8,
    snap_b: ?[]const u8,
) ![]PeriphDelta {
    if (snap_a == null and snap_b == null) return &.{};
    var list: std.ArrayList(PeriphDelta) = .empty;
    defer list.deinit(allocator);

    if (snap_b) |sb| {
        var reader = file.Reader.open(sb) catch return &.{};
        while (reader.next() catch null) |sec| {
            if (isCoreOrMemorySection(sec.kind)) continue;
            const pay_a = if (snap_a) |sa| findSection(sa, sec.kind) else null;
            if (comparePayloads(sec.payload, pay_a)) |delta| {
                try list.append(allocator, .{
                    .unit = @tagName(sec.kind),
                    .kind = sec.kind,
                    .offset = delta.offset,
                    .old_val = delta.old_val,
                    .new_val = delta.new_val,
                    .changed_bytes = delta.changed_bytes,
                });
            }
        }
    }
    return list.toOwnedSlice(allocator);
}

fn isCoreOrMemorySection(k: file.Kind) bool {
    return k == .cpu or k == .second or k == .memory or k == .second_memory or k == .image;
}

const DeltaInfo = struct {
    offset: u32,
    old_val: u32,
    new_val: u32,
    changed_bytes: u32,
};

fn comparePayloads(b: []const u8, a: ?[]const u8) ?DeltaInfo {
    const pa = a orelse {
        const val: u32 = if (b.len >= 4) std.mem.readInt(u32, b[0..4], .little) else 0;
        return .{ .offset = 0, .old_val = 0, .new_val = val, .changed_bytes = @intCast(b.len) };
    };
    if (std.mem.eql(u8, a.?, b)) return null;

    var first_diff: ?u32 = null;
    var changed: u32 = 0;
    const min_len = @min(pa.len, b.len);
    for (0..min_len) |i| {
        if (pa[i] != b[i]) {
            if (first_diff == null) first_diff = @intCast(i);
            changed += 1;
        }
    }
    const len_diff: u32 = @intCast(if (pa.len > b.len) pa.len - b.len else b.len - pa.len);
    changed += len_diff;

    const off = first_diff orelse @as(u32, @intCast(min_len));
    const old_w = readWordAt(pa, off);
    const new_w = readWordAt(b, off);
    return .{ .offset = off, .old_val = old_w, .new_val = new_w, .changed_bytes = changed };
}

fn readWordAt(data: []const u8, off: u32) u32 {
    const start: usize = @intCast(off);
    if (start >= data.len) return 0;
    var buf: [4]u8 = @splat(0);
    const avail = @min(4, data.len - start);
    @memcpy(buf[0..avail], data[start .. start + avail]);
    return std.mem.readInt(u32, &buf, .little);
}

pub fn diffSnapshots(
    allocator: std.mem.Allocator,
    pos_a: Position,
    pos_b: Position,
    snap_a: ?[]const u8,
    snap_b: []const u8,
) !DiffResult {
    const c0_a = if (snap_a) |s| decodeCoreRegs(s, 0) else null;
    const c0_b = decodeCoreRegs(snap_b, 0);
    const c1_a = if (snap_a) |s| decodeCoreRegs(s, 1) else null;
    const c1_b = decodeCoreRegs(snap_b, 1);

    const r0 = try diffCoreRegs(allocator, c0_a, c0_b);
    errdefer allocator.free(r0);
    const r1 = try diffCoreRegs(allocator, c1_a, c1_b);
    errdefer allocator.free(r1);
    const periphs = try diffPeripherals(allocator, snap_a, snap_b);
    errdefer allocator.free(periphs);

    return .{
        .pos_a = pos_a,
        .pos_b = pos_b,
        .cpu0_regs = r0,
        .cpu1_regs = r1,
        .pages = &.{},
        .periphs = periphs,
    };
}

pub fn diffManifests(
    allocator: std.mem.Allocator,
    manifest_a: ?*const manifest_mod.Manifest,
    manifest_b: *const manifest_mod.Manifest,
    get_blob: ?*const fn (ctx: *anyopaque, id: ObjectId) ?[]const u8,
    blob_ctx: ?*anyopaque,
) !DiffResult {
    const pos_a = if (manifest_a) |m| m.position else Position{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired };
    const pos_b = manifest_b.position;

    const pages = try diffPages(allocator, manifest_a, manifest_b);
    errdefer allocator.free(pages);

    var snap_a: ?[]const u8 = null;
    var snap_b: ?[]const u8 = null;

    if (get_blob) |getter| {
        if (blob_ctx) |ctx| {
            if (manifest_a) |ma| {
                for (ma.blobs) |b| {
                    if (b.space == .run_state) snap_a = getter(ctx, b.object);
                }
            }
            for (manifest_b.blobs) |b| {
                if (b.space == .run_state) snap_b = getter(ctx, b.object);
            }
        }
    }

    const c0_a = if (snap_a) |s| decodeCoreRegs(s, 0) else null;
    const c0_b = if (snap_b) |s| decodeCoreRegs(s, 0) else null;
    const c1_a = if (snap_a) |s| decodeCoreRegs(s, 1) else null;
    const c1_b = if (snap_b) |s| decodeCoreRegs(s, 1) else null;

    const r0 = try diffCoreRegs(allocator, c0_a, c0_b);
    errdefer allocator.free(r0);
    const r1 = try diffCoreRegs(allocator, c1_a, c1_b);
    errdefer allocator.free(r1);
    const periphs = try diffPeripherals(allocator, snap_a, snap_b);
    errdefer allocator.free(periphs);

    return .{
        .pos_a = pos_a,
        .pos_b = pos_b,
        .cpu0_regs = r0,
        .cpu1_regs = r1,
        .pages = pages,
        .periphs = periphs,
    };
}
