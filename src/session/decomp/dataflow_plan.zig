//! Internal transfer, spill cache, state init/merge, and definition planning for `dataflow.zig` (RA8EMU-1354).
const std = @import("std");

const aapcs = @import("aapcs.zig");
const bus = @import("ra8_chip").core.cpu.bus;
const cfg_mod = @import("cfg.zig");
const effects = @import("effects.zig");
const it_state = @import("ra8_chip").core.cpu.it_state;
const value = @import("value.zig");

pub const DefId = u32;
pub const InsnIndex = u32;

/// Origin class of a single static register definition inside a function.
pub const DefKind = enum {
    entry,
    insn,
    call_ret,
    call_clobber,
};

/// Single register definition site assigned before dataflow iteration.
pub const DefSite = struct {
    id: DefId,
    reg: u4,
    kind: DefKind,
    insn_idx: ?InsnIndex = null,
    address: u32,
};

pub const BlockSpan = struct {
    first_insn: u32 = 0,
    clobber_start: ?u32 = null,
    has_call_clobber: bool = false,
};

pub const BlockState = struct {
    defs: std.DynamicBitSetUnmanaged,
    regs: [16]value.Value,
    flags: value.FlagState,
    it: it_state.Itstate,
    visited: bool,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    total_insns: usize = 0,
    defs: std.ArrayListUnmanaged(DefSite) = .empty,
    reg_defs: [16]std.ArrayListUnmanaged(DefId) = @splat(.empty),
    insn_def_start: []u32,
    block_spans: []BlockSpan,

    pub fn build(allocator: std.mem.Allocator, cfg: *const cfg_mod.Cfg, target_bus: bus.Bus) !Plan {
        var total: usize = 0;
        for (cfg.blocks) |blk| {
            total += blk.insns.len;
        }
        var plan: Plan = .{
            .allocator = allocator,
            .total_insns = total,
            .insn_def_start = try allocator.alloc(u32, total),
            .block_spans = try allocator.alloc(BlockSpan, cfg.blocks.len),
        };
        errdefer plan.deinit();

        var r: usize = 0;
        while (r < 16) : (r += 1) {
            try plan.addDef(@intCast(r), .entry, null, cfg.entry);
        }

        const unknown_regs: [16]value.Value = @splat(.unknown);
        const dummy_state: effects.State = .{ .regs = &unknown_regs, .bus = target_bus };
        var insn_cursor: u32 = 0;

        for (cfg.blocks, 0..) |blk, b_idx| {
            plan.block_spans[b_idx] = .{ .first_insn = insn_cursor };
            for (blk.insns) |ci| {
                const eff = effects.evaluate(&dummy_state, ci.instr, ci.hit);
                plan.insn_def_start[insn_cursor] = @intCast(plan.defs.items.len);
                try plan.addMaskDefs(eff.defs_mask, insn_cursor, ci.instr.address);
                insn_cursor += 1;
            }
            if (blk.insns.len > 0 and (blk.summary.kind == .call or blk.summary.kind == .indirect_call)) {
                const last_addr = blk.insns[blk.insns.len - 1].instr.address;
                plan.block_spans[b_idx].has_call_clobber = true;
                plan.block_spans[b_idx].clobber_start = @intCast(plan.defs.items.len);
                try plan.addCallClobberDefs(insn_cursor - 1, last_addr);
            }
        }
        return plan;
    }

    pub fn deinit(self: *Plan) void {
        self.defs.deinit(self.allocator);
        for (&self.reg_defs) |*list| {
            list.deinit(self.allocator);
        }
        self.allocator.free(self.insn_def_start);
        self.allocator.free(self.block_spans);
    }

    fn addDef(self: *Plan, reg: u4, kind: DefKind, insn_idx: ?InsnIndex, address: u32) !void {
        const id: DefId = @intCast(self.defs.items.len);
        try self.defs.append(self.allocator, .{
            .id = id,
            .reg = reg,
            .kind = kind,
            .insn_idx = insn_idx,
            .address = address,
        });
        try self.reg_defs[reg].append(self.allocator, id);
    }

    fn addMaskDefs(self: *Plan, mask: u16, insn_idx: InsnIndex, address: u32) !void {
        var rem = mask;
        while (rem != 0) {
            const bit_idx: u4 = @intCast(@ctz(rem));
            try self.addDef(bit_idx, .insn, insn_idx, address);
            rem &= rem - 1;
        }
    }

    fn addCallClobberDefs(self: *Plan, insn_idx: InsnIndex, address: u32) !void {
        const regs = [_]u4{ 0, 1, 2, 3, 12, 14 };
        for (regs) |r| {
            try self.addDef(r, if (r == 0) .call_ret else .call_clobber, insn_idx, address);
        }
    }
};

const SpillSlot = struct {
    offset: i32 = 0,
    size: u3 = 4,
    val: value.Value = .unknown,
    valid: bool = false,
};

pub const SpillCache = struct {
    slots: [8]SpillSlot = @splat(.{}),
    next_victim: usize = 0,

    pub fn clear(self: *SpillCache) void {
        for (&self.slots) |*s| {
            s.valid = false;
        }
    }

    pub fn put(self: *SpillCache, off: i32, size: u3, val: value.Value) void {
        const end: i64 = @as(i64, off) + size;
        var empty_idx: ?usize = null;
        for (&self.slots, 0..) |*s, i| {
            if (!s.valid) {
                if (empty_idx == null) empty_idx = i;
                continue;
            }
            const s_end: i64 = @as(i64, s.offset) + s.size;
            if (off < s_end and s.offset < end) s.valid = false;
        }
        const target = empty_idx orelse blk: {
            const idx = self.next_victim;
            self.next_victim = (idx + 1) % self.slots.len;
            break :blk idx;
        };
        self.slots[target] = .{ .offset = off, .size = size, .val = val, .valid = true };
    }

    pub fn get(self: *const SpillCache, off: i32, size: u3, signed: bool) ?value.Value {
        for (self.slots) |s| {
            if (!s.valid or s.offset != off or s.size != size) continue;
            if (s.val.asConstant()) |raw| return .{ .constant = maskConstant(raw, size, signed) };
            if (!signed and size == 4) return s.val;
            if (!signed and size < 4 and s.val == .call_result) return s.val;
            return null;
        }
        return null;
    }
};

fn maskConstant(raw: u32, size: u3, signed: bool) u32 {
    return switch (size) {
        1 => if (signed) @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(raw)))))) else raw & 0xFF,
        2 => if (signed) @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(raw)))))) else raw & 0xFFFF,
        else => raw,
    };
}

pub fn initBlockStates(allocator: std.mem.Allocator, cfg: *const cfg_mod.Cfg, plan: *const Plan) ![]BlockState {
    const states = try allocator.alloc(BlockState, cfg.blocks.len);
    errdefer allocator.free(states);
    var inited: usize = 0;
    errdefer {
        for (states[0..inited]) |*st| {
            st.defs.deinit(allocator);
        }
    }
    for (states) |*st| {
        st.* = .{
            .defs = try std.DynamicBitSetUnmanaged.initEmpty(allocator, plan.defs.items.len),
            .regs = @splat(.unvisited),
            .flags = .unvisited,
            .it = 0,
            .visited = false,
        };
        inited += 1;
    }
    if (states.len > 0) {
        var r: usize = 0;
        while (r < 16) : (r += 1) {
            states[0].defs.set(r);
            states[0].regs[r] = switch (r) {
                13 => .{ .sp_offset = 0 },
                15 => .{ .constant = cfg.entry +% 4 },
                else => .{ .entry_reg = @intCast(r) },
            };
        }
        states[0].flags = .unknown;
        states[0].visited = true;
    }
    return states;
}

pub fn freeBlockStates(allocator: std.mem.Allocator, states: []BlockState) void {
    for (states) |*st| {
        st.defs.deinit(allocator);
    }
    allocator.free(states);
}

pub fn mergeInto(
    dst: *BlockState,
    src_defs: *const std.DynamicBitSetUnmanaged,
    src_regs: *const [16]value.Value,
    src_flags: value.FlagState,
    out_it: it_state.Itstate,
) bool {
    var changed = !dst.visited;
    dst.visited = true;
    var r: usize = 0;
    while (r < 16) : (r += 1) {
        const joined = value.joinValue(dst.regs[r], src_regs[r]);
        if (!dst.regs[r].eql(joined)) {
            dst.regs[r] = joined;
            changed = true;
        }
    }
    const joined_flags = value.joinFlags(dst.flags, src_flags);
    if (!dst.flags.eql(joined_flags)) {
        dst.flags = joined_flags;
        changed = true;
    }
    if (it_state.active(out_it) and dst.it != out_it) {
        dst.it = out_it;
        changed = true;
    }
    if (!src_defs.subsetOf(dst.defs)) {
        dst.defs.setUnion(src_defs.*);
        changed = true;
    }
    return changed;
}

pub fn resolveMemAndAdvanceSpills(regs: *const [16]value.Value, spills: *SpillCache, eff: effects.Effect) value.Value {
    var rd_val = eff.primary_val;
    if (eff.mem) |m| {
        const addr = value.evalAdd(regs[m.base_reg], m.offset);
        if (addr == .sp_offset) {
            if (!m.load) {
                spills.put(addr.sp_offset, m.size, regs[m.rt]);
            } else if (spills.get(addr.sp_offset, m.size, m.signed)) |fwd| {
                rd_val = fwd;
            }
        }
    }
    if (eff.clears_spills or eff.is_call) spills.clear();
    return rd_val;
}

pub fn applyEffects(
    plan: *const Plan,
    insn_idx: InsnIndex,
    address: u32,
    eff: effects.Effect,
    rd_val: value.Value,
    defs_set: *std.DynamicBitSetUnmanaged,
    regs: *[16]value.Value,
    flags: *value.FlagState,
) void {
    var def_cursor = plan.insn_def_start[insn_idx];
    var rem = eff.defs_mask;
    while (rem != 0) {
        const r: u4 = @intCast(@ctz(rem));
        for (plan.reg_defs[r].items) |old_id| {
            defs_set.unset(old_id);
        }
        defs_set.set(def_cursor);
        def_cursor += 1;
        regs[r] = if (eff.primary_rd == r)
            rd_val
        else if (eff.secondary_rd == r)
            eff.secondary_val
        else if (eff.wback_reg == r)
            eff.wback_val
        else
            .unknown;
        rem &= rem - 1;
    }
    if (eff.writes_flags) |fu| {
        flags.* = .{ .known = .{
            .setter_insn = insn_idx,
            .setter_addr = address,
            .kind = fu.kind,
            .lhs_reg = fu.lhs_reg,
            .rhs_reg = fu.rhs_reg,
            .rhs_imm = fu.rhs_imm,
            .lhs_val = fu.lhs_val,
            .rhs_val = fu.rhs_val,
        } };
    }
}

pub fn applyCallClobber(
    plan: *const Plan,
    clobber_start: u32,
    call_addr: u32,
    defs_set: *std.DynamicBitSetUnmanaged,
    regs: *[16]value.Value,
    flags: *value.FlagState,
) void {
    const clobbered = [_]u4{ 0, 1, 2, 3, 12, 14 };
    for (clobbered, 0..) |r, idx| {
        for (plan.reg_defs[r].items) |old_id| {
            defs_set.unset(old_id);
        }
        defs_set.set(clobber_start + @as(u32, @intCast(idx)));
    }
    aapcs.clobberCall(regs, flags, call_addr);
}

pub fn advanceIt(cur_it: *it_state.Itstate, group: []const u8, hw1: u16, was_in_it: bool) void {
    if (std.mem.eql(u8, group, "it")) {
        cur_it.* = @truncate(hw1 & 0xFF);
    } else if (was_in_it) {
        cur_it.* = it_state.advance(cur_it.*);
    }
}
