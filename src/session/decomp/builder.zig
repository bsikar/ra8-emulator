//! Two-pass static CFG reconstructor for Thumb-2 functions (RA8EMU-1353).
//!
//! Pass 1 walks reachable control flow from the entry point across block
//! boundaries and 32-instruction caps to collect all basic-block leaders.
//! Pass 2 splits runs cleanly at every leader, wires intra-procedural blocks,
//! links call/tail targets through the symbol layer, and records computed edges.
const std = @import("std");

const block = @import("ra8_chip").core.cpu.decode.block;
const bus = @import("ra8_chip").core.cpu.bus;
const cfg_mod = @import("cfg.zig");
const decode = @import("ra8_chip").core.cpu.decode;
const elf = @import("ra8_board").image.elf;
const extents_mod = @import("extents.zig");
const Instr = @import("ra8_chip").core.cpu.instr.Instr;
const symbols = @import("../symbols.zig");

/// Options governing static CFG reconstruction for one function entry.
pub const Options = struct {
    image: ?elf.Image = null,
    bus: bus.Bus,
    decode_cache: *decode.cache.DecodeCache,
    profile: decode.profile.Profile = decode.profile.Profile.m85,
    extents: []const extents_mod.FunctionExtent = &.{},
    extent: ?extents_mod.FunctionExtent = null,
    entry: u32,
    max_blocks: usize = 1024,
};

const WorkItem = struct { addr: u32, it_slots: u3 };

const Discovery = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    norm_entry: u32,
    fn_extent: ?extents_mod.FunctionExtent,
    leaders: std.AutoHashMapUnmanaged(u32, u3) = .empty,
    scanned: std.AutoHashMapUnmanaged(u32, void) = .empty,
    queue: std.ArrayListUnmanaged(WorkItem) = .empty,
    truncated: bool = false,

    fn deinit(self: *Discovery) void {
        self.leaders.deinit(self.allocator);
        self.scanned.deinit(self.allocator);
        self.queue.deinit(self.allocator);
    }

    fn run(self: *Discovery) std.mem.Allocator.Error!void {
        try self.addLeader(self.norm_entry, 0);
        var head: usize = 0;
        while (head < self.queue.items.len) : (head += 1) {
            const item = self.queue.items[head];
            if (self.scanned.contains(item.addr)) continue;
            try self.scanned.put(self.allocator, item.addr, {});
            try self.scanRun(item.addr, item.it_slots);
        }
    }

    fn addLeader(self: *Discovery, addr: u32, it_slots: u3) std.mem.Allocator.Error!void {
        if (self.leaders.getPtr(addr)) |prev| {
            if (it_slots > prev.*) prev.* = it_slots;
            return;
        }
        if (self.leaders.count() >= self.opts.max_blocks) {
            self.truncated = true;
            return;
        }
        try self.leaders.put(self.allocator, addr, it_slots);
        try self.queue.append(self.allocator, .{ .addr = addr, .it_slots = it_slots });
    }

    fn scanRun(self: *Discovery, start_addr: u32, init_it: u3) std.mem.Allocator.Error!void {
        const blk = block.Block.form(self.opts.bus, self.opts.decode_cache, self.opts.profile, start_addr);
        if (blk.len == 0) return;

        const last = blk.items()[blk.len - 1].instr;
        const ends_block = block.ends(last);
        const last_in_it = init_it > 0 and (blk.len - 1) < init_it;

        // If formation stopped below cap without an ending instruction, fetch/decode already failed at end.
        if (!ends_block and blk.len < block.cap) return;

        const summary = block.flow.fromBlock(blk, last_in_it);
        if (summary.target) |raw_tgt| {
            const tgt = raw_tgt & ~@as(u32, 1);
            if ((summary.kind == .branch or summary.kind == .cond_branch) and self.isIntraBranch(tgt)) {
                try self.addLeader(tgt, 0);
            }
        }
        const next_it: u3 = if (summary.kind == .it_block) summary.it_slots else 0;
        const ft = summary.fallthrough orelse return;
        if (!self.canFollowFallthrough(ft, summary.kind)) return;
        try self.addLeader(ft, next_it);
    }

    fn isIntraBranch(self: *const Discovery, norm_tgt: u32) bool {
        if (extents_mod.findByEntry(self.opts.extents, norm_tgt)) |other| {
            if (other.entry != self.norm_entry) return false;
        }
        if (self.fn_extent) |ext| {
            if (ext.size > 0) return insideExtent(ext, norm_tgt);
        }
        if (self.opts.image) |img| {
            if (symbols.inside(img, norm_tgt)) |hit| {
                if ((norm_tgt -% hit.offset) != self.norm_entry) return false;
            }
        }
        return self.opts.bus.allowsExec(norm_tgt, 2);
    }

    fn canFollowFallthrough(self: *const Discovery, addr: u32, kind: block.flow.Kind) bool {
        if (self.fn_extent) |ext| {
            if (ext.size > 0 and !insideExtent(ext, addr)) return false;
        }
        if (extents_mod.findByEntry(self.opts.extents, addr)) |other| {
            if (other.entry != self.norm_entry) return false;
        }
        // Guard against falling through a trailing noreturn call into an inline literal pool.
        if (kind == .call or kind == .indirect_call or kind == .svc) {
            return canDecodeOne(self.opts, addr);
        }
        return self.opts.bus.allowsExec(addr, 2);
    }
};

/// Reconstruct one function's static CFG starting at `opts.entry`.
pub fn build(allocator: std.mem.Allocator, opts: Options) std.mem.Allocator.Error!cfg_mod.Cfg {
    const norm_entry = opts.entry & ~@as(u32, 1);
    const fn_extent = opts.extent orelse
        if (extents_mod.findContaining(opts.extents, norm_entry)) |found| found.* else null;

    var discovery = Discovery{
        .allocator = allocator,
        .opts = opts,
        .norm_entry = norm_entry,
        .fn_extent = fn_extent,
    };
    defer discovery.deinit();
    try discovery.run();

    const sorted = try sortedLeaderKeys(allocator, &discovery.leaders);
    defer allocator.free(sorted);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const blocks = try aa.alloc(cfg_mod.BasicBlock, sorted.len);
    var unresolved: std.ArrayListUnmanaged(cfg_mod.UnresolvedEdge) = .empty;
    var pred_lists = try allocator.alloc(std.ArrayListUnmanaged(cfg_mod.BlockId), sorted.len);
    defer {
        for (pred_lists) |*p| {
            p.deinit(allocator);
        }
        allocator.free(pred_lists);
    }
    @memset(pred_lists, .empty);

    for (sorted, 0..) |start_addr, idx| {
        const id: cfg_mod.BlockId = @intCast(idx);
        const it_slots = discovery.leaders.get(start_addr) orelse 0;
        const built = try materializeBlock(aa, opts, sorted, id, start_addr, it_slots);
        blocks[idx] = built.blk;
        for (built.blk.succs) |edge| {
            if (edge.target_block) |dst| try appendUnique(&pred_lists[dst], allocator, id);
            if (edge.unresolved) |reason| {
                try unresolved.append(aa, .{ .from_block = id, .at_address = built.last_addr, .reason = reason });
            }
        }
    }

    for (blocks, 0..) |*blk, idx| {
        blk.preds = try aa.dupe(cfg_mod.BlockId, pred_lists[idx].items);
    }

    const out_name = try dupeOpt(aa, if (fn_extent) |e| e.name else null);
    const out_unresolved = try unresolved.toOwnedSlice(aa);

    return .{
        .arena = arena,
        .entry = norm_entry,
        .extent_size = if (fn_extent) |e| e.size else 0,
        .name = out_name,
        .blocks = blocks,
        .unresolved = out_unresolved,
        .truncated = discovery.truncated,
    };
}

const BuiltBlock = struct {
    blk: cfg_mod.BasicBlock,
    last_addr: u32,
};

fn materializeBlock(
    aa: std.mem.Allocator,
    opts: Options,
    sorted_leaders: []const u32,
    id: cfg_mod.BlockId,
    start_addr: u32,
    it_slots: u3,
) std.mem.Allocator.Error!BuiltBlock {
    var insns: std.ArrayListUnmanaged(cfg_mod.Insn) = .empty;
    var pc = start_addr;
    var stopped_invalid = false;

    while (insns.items.len < block.cap) {
        const instr = Instr.fetch(opts.bus, pc) catch {
            stopped_invalid = true;
            break;
        };
        const hit = opts.decode_cache.findFor(opts.profile, instr) orelse {
            stopped_invalid = true;
            break;
        };
        try insns.append(aa, .{ .instr = instr, .hit = hit });
        pc = instr.address +% instr.size;
        if (block.ends(instr)) break;
        if (findLeaderId(sorted_leaders, pc) != null) break;
    }

    const summary = computeSummary(insns.items, it_slots, pc, stopped_invalid);
    const last_addr = if (insns.items.len > 0) insns.items[insns.items.len - 1].instr.address else start_addr;
    const succs = try buildEdges(aa, opts, sorted_leaders, summary);
    return .{
        .blk = .{
            .id = id,
            .start = start_addr,
            .end = pc,
            .summary = summary,
            .insns = try insns.toOwnedSlice(aa),
            .succs = succs,
            .preds = &.{},
        },
        .last_addr = last_addr,
    };
}

fn computeSummary(
    insns: []const cfg_mod.Insn,
    it_slots: u3,
    end_pc: u32,
    stopped_invalid: bool,
) block.flow.EdgeSummary {
    if (insns.len == 0) return .{ .kind = .halt, .decode_stop = true };
    const last = insns[insns.len - 1].instr;
    const last_in_it = it_slots > 0 and (insns.len - 1) < it_slots;
    if (!block.ends(last)) {
        if (stopped_invalid) return .{ .kind = .halt, .decode_stop = true };
        return .{ .kind = .fallthrough, .fallthrough = end_pc };
    }
    return block.flow.classify(last, last_in_it);
}

fn buildEdges(
    aa: std.mem.Allocator,
    opts: Options,
    sorted_leaders: []const u32,
    summary: block.flow.EdgeSummary,
) std.mem.Allocator.Error![]const cfg_mod.Edge {
    var edges: std.ArrayListUnmanaged(cfg_mod.Edge) = .empty;
    switch (summary.kind) {
        .fallthrough, .it_block => try addFallthroughEdge(aa, &edges, sorted_leaders, summary.fallthrough),
        .branch => try addBranchTargetEdge(aa, opts, &edges, sorted_leaders, summary.target),
        .cond_branch => {
            try addBranchTargetEdge(aa, opts, &edges, sorted_leaders, summary.target);
            try addNotTakenEdge(aa, &edges, sorted_leaders, summary.fallthrough);
        },
        .call => {
            if (summary.target) |tgt| {
                const res = extents_mod.resolveTarget(opts.image, opts.extents, tgt);
                try edges.append(aa, .{
                    .kind = .call,
                    .target_address = res.address,
                    .target_name = try dupeOpt(aa, res.name),
                });
            }
            try addFallthroughEdge(aa, &edges, sorted_leaders, summary.fallthrough);
        },
        .indirect_call => {
            try edges.append(aa, .{ .kind = .indirect_call, .unresolved = summary.unresolved });
            try addFallthroughEdge(aa, &edges, sorted_leaders, summary.fallthrough);
        },
        .svc => {
            try edges.append(aa, .{ .kind = .svc });
            try addFallthroughEdge(aa, &edges, sorted_leaders, summary.fallthrough);
        },
        .indirect_jump => {
            try edges.append(aa, .{ .kind = .indirect_jump, .unresolved = summary.unresolved });
            try addFallthroughEdge(aa, &edges, sorted_leaders, summary.fallthrough);
        },
        .ret, .halt => try addFallthroughEdge(aa, &edges, sorted_leaders, summary.fallthrough),
    }
    return edges.toOwnedSlice(aa);
}

fn addFallthroughEdge(
    aa: std.mem.Allocator,
    edges: *std.ArrayListUnmanaged(cfg_mod.Edge),
    sorted_leaders: []const u32,
    fallthrough: ?u32,
) std.mem.Allocator.Error!void {
    const ft = fallthrough orelse return;
    const dst = findLeaderId(sorted_leaders, ft) orelse return;
    try edges.append(aa, .{ .kind = .fallthrough, .target_block = dst, .target_address = ft });
}

fn addNotTakenEdge(
    aa: std.mem.Allocator,
    edges: *std.ArrayListUnmanaged(cfg_mod.Edge),
    sorted_leaders: []const u32,
    fallthrough: ?u32,
) std.mem.Allocator.Error!void {
    const ft = fallthrough orelse return;
    const dst = findLeaderId(sorted_leaders, ft) orelse return;
    try edges.append(aa, .{ .kind = .branch_not_taken, .target_block = dst, .target_address = ft });
}

fn addBranchTargetEdge(
    aa: std.mem.Allocator,
    opts: Options,
    edges: *std.ArrayListUnmanaged(cfg_mod.Edge),
    sorted_leaders: []const u32,
    target: ?u32,
) std.mem.Allocator.Error!void {
    const raw = target orelse return;
    const norm = raw & ~@as(u32, 1);
    if (findLeaderId(sorted_leaders, norm)) |dst| {
        try edges.append(aa, .{ .kind = .branch_taken, .target_block = dst, .target_address = norm });
        return;
    }
    const res = extents_mod.resolveTarget(opts.image, opts.extents, norm);
    try edges.append(aa, .{
        .kind = .tail_call,
        .target_address = res.address,
        .target_name = try dupeOpt(aa, res.name),
    });
}

fn sortedLeaderKeys(allocator: std.mem.Allocator, map: *const std.AutoHashMapUnmanaged(u32, u3)) ![]u32 {
    const keys = try allocator.alloc(u32, map.count());
    var iter = map.keyIterator();
    var idx: usize = 0;
    while (iter.next()) |key_ptr| : (idx += 1) {
        keys[idx] = key_ptr.*;
    }
    std.mem.sort(u32, keys, {}, std.sort.asc(u32));
    return keys;
}

fn findLeaderId(sorted: []const u32, addr: u32) ?cfg_mod.BlockId {
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (sorted[mid] < addr) {
            low = mid + 1;
        } else if (sorted[mid] > addr) {
            high = mid;
        } else {
            return @intCast(mid);
        }
    }
    return null;
}

fn insideExtent(ext: extents_mod.FunctionExtent, addr: u32) bool {
    const start: u64 = ext.entry;
    const end: u64 = start + ext.size;
    return @as(u64, addr) >= start and @as(u64, addr) < end;
}

fn canDecodeOne(opts: Options, addr: u32) bool {
    const instr = Instr.fetch(opts.bus, addr) catch return false;
    return opts.decode_cache.findFor(opts.profile, instr) != null;
}

fn appendUnique(
    list: *std.ArrayListUnmanaged(cfg_mod.BlockId),
    allocator: std.mem.Allocator,
    val: cfg_mod.BlockId,
) !void {
    for (list.items) |existing| if (existing == val) return;
    try list.append(allocator, val);
}

fn dupeOpt(aa: std.mem.Allocator, val: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    const slice = val orelse return null;
    return try aa.dupe(u8, slice);
}
