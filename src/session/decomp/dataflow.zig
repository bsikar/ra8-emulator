//! Per-function iterative AAPCS32 def-use and condition-pairing analysis (RA8EMU-1354).
const std = @import("std");

const aapcs = @import("aapcs.zig");
const bus = @import("ra8_chip").core.cpu.bus;
const cfg_mod = @import("cfg.zig");
const effects = @import("effects.zig");
const it_state = @import("ra8_chip").core.cpu.it_state;
const plan_mod = @import("dataflow_plan.zig");
const value = @import("value.zig");

pub const DefId = plan_mod.DefId;
pub const InsnIndex = plan_mod.InsnIndex;
pub const DefKind = plan_mod.DefKind;
pub const DefSite = plan_mod.DefSite;

/// Reaching definition IDs for one source register read by an instruction.
pub const RegUseDefs = struct {
    reg: u4,
    defs: []const DefId,
};

/// Dataflow facts observed at one instruction site after fixpoint convergence.
pub const InsnFlow = struct {
    insn_idx: InsnIndex,
    block_id: cfg_mod.BlockId,
    address: u32,
    uses_mask: u16,
    defs_mask: u16,
    primary_rd: ?u4,
    primary_val: value.Value,
    cond_active: ?u4,
    reg_defs: []const RegUseDefs,
};

/// Options configuring `analyze`.
pub const Options = struct {
    bus: bus.Bus,
    max_block_visits: usize = 32,
};

/// Arena-backed def-use, constant/pair value, condition pairing, and ABI facts for one CFG.
pub const Dataflow = struct {
    arena: std.heap.ArenaAllocator,
    insns: []const InsnFlow,
    defs: []const DefSite,
    def_uses: []const []const InsnIndex,
    cond_pairs: []const value.ConditionPair,
    calls: []const aapcs.CallSite,
    pairs: []const value.RegPair,
    signature: aapcs.SignatureSummary,
    converged: bool = true,

    pub fn deinit(self: *Dataflow) void {
        self.arena.deinit();
    }

    /// Binary-search instruction flow facts by normalized address.
    pub fn insnAt(self: *const Dataflow, address: u32) ?*const InsnFlow {
        const norm = address & ~@as(u32, 1);
        var low: usize = 0;
        var high: usize = self.insns.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.insns[mid].address < norm) {
                low = mid + 1;
            } else if (self.insns[mid].address > norm) {
                high = mid;
            } else {
                return &self.insns[mid];
            }
        }
        return null;
    }

    /// Return the reaching definition IDs for source register `reg` at `insn_idx`.
    pub fn defsReaching(self: *const Dataflow, insn_idx: InsnIndex, reg: u4) []const DefId {
        if (insn_idx >= self.insns.len) return &.{};
        for (self.insns[insn_idx].reg_defs) |entry| {
            if (entry.reg == reg) return entry.defs;
        }
        return &.{};
    }
};

/// Run iterative AAPCS32 def-use dataflow over `cfg`.
pub fn analyze(allocator: std.mem.Allocator, cfg: *const cfg_mod.Cfg, opts: Options) !Dataflow {
    var plan = try plan_mod.Plan.build(allocator, cfg, opts.bus);
    defer plan.deinit();

    const states = try plan_mod.initBlockStates(allocator, cfg, &plan);
    defer plan_mod.freeBlockStates(allocator, states);

    const converged = try runWorklist(allocator, cfg, &plan, opts, states);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    return collectResults(arena, allocator, cfg, &plan, opts, states, converged);
}

fn runWorklist(
    allocator: std.mem.Allocator,
    cfg: *const cfg_mod.Cfg,
    plan: *const plan_mod.Plan,
    opts: Options,
    states: []plan_mod.BlockState,
) !bool {
    if (cfg.blocks.len == 0) return true;
    var work_defs = try std.DynamicBitSetUnmanaged.initEmpty(allocator, plan.defs.items.len);
    defer work_defs.deinit(allocator);
    var worklist: std.ArrayListUnmanaged(cfg_mod.BlockId) = .empty;
    defer worklist.deinit(allocator);
    try worklist.append(allocator, 0);

    var head: usize = 0;
    const limit = opts.max_block_visits * cfg.blocks.len;
    var visits: usize = 0;

    while (head < worklist.items.len) : (head += 1) {
        if (visits >= limit) return false;
        visits += 1;
        const bid = worklist.items[head];
        const blk = &cfg.blocks[bid];

        work_defs.unsetAll();
        work_defs.setUnion(states[bid].defs);
        var regs = states[bid].regs;
        var flags = states[bid].flags;
        var cur_it = states[bid].it;

        stepBlock(blk, plan, opts.bus, &work_defs, &regs, &flags, &cur_it);

        for (blk.succs) |edge| {
            const dst = edge.target_block orelse continue;
            if (plan_mod.mergeInto(&states[dst], &work_defs, &regs, flags, cur_it)) {
                try worklist.append(allocator, dst);
            }
        }
    }
    return true;
}

fn stepBlock(
    blk: *const cfg_mod.BasicBlock,
    plan: *const plan_mod.Plan,
    target_bus: bus.Bus,
    defs_set: *std.DynamicBitSetUnmanaged,
    regs: *[16]value.Value,
    flags: *value.FlagState,
    cur_it: *it_state.Itstate,
) void {
    var spills: plan_mod.SpillCache = .{};
    const span = plan.block_spans[blk.id];
    for (blk.insns, 0..) |ci, local_idx| {
        const insn_idx = span.first_insn + @as(u32, @intCast(local_idx));
        const in_it = it_state.active(cur_it.*);
        const state: effects.State = .{
            .regs = regs,
            .bus = target_bus,
            .in_it = in_it,
            .it_cond = if (in_it) it_state.condition(cur_it.*) else null,
        };
        const eff = effects.evaluate(&state, ci.instr, ci.hit);
        const rd_val = plan_mod.resolveMemAndAdvanceSpills(regs, &spills, eff);
        plan_mod.applyEffects(plan, insn_idx, ci.instr.address, eff, rd_val, defs_set, regs, flags);
        plan_mod.advanceIt(cur_it, ci.hit.group, ci.instr.hw1, in_it);
    }
    if (span.has_call_clobber and blk.insns.len > 0) {
        const last_addr = blk.insns[blk.insns.len - 1].instr.address;
        plan_mod.applyCallClobber(plan, span.clobber_start.?, last_addr, defs_set, regs, flags);
    }
}

const Collector = struct {
    aa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    plan: *const plan_mod.Plan,
    target_bus: bus.Bus,
    insn_flows: []InsnFlow,
    use_lists: []std.ArrayListUnmanaged(InsnIndex),
    cur_defs: std.DynamicBitSetUnmanaged,
    cond_pairs: std.ArrayListUnmanaged(value.ConditionPair) = .empty,
    calls: std.ArrayListUnmanaged(aapcs.CallSite) = .empty,
    pairs: std.ArrayListUnmanaged(value.RegPair) = .empty,
    saved_callee: u16 = 0,
    ret_kind: aapcs.ReturnKind = .none,

    fn visitBlock(self: *Collector, blk: cfg_mod.BasicBlock, st: plan_mod.BlockState) !void {
        if (!st.visited) return;
        self.cur_defs.unsetAll();
        self.cur_defs.setUnion(st.defs);
        var regs = st.regs;
        var flags = st.flags;
        var cur_it = st.it;
        var spills: plan_mod.SpillCache = .{};
        const span = self.plan.block_spans[blk.id];

        for (blk.insns, 0..) |ci, local_idx| {
            const insn_idx = span.first_insn + @as(u32, @intCast(local_idx));
            const in_it = it_state.active(cur_it);
            const active_cond: ?u4 = if (in_it) it_state.condition(cur_it) else null;
            const state: effects.State = .{
                .regs = &regs,
                .bus = self.target_bus,
                .in_it = in_it,
                .it_cond = active_cond,
            };
            const eff = effects.evaluate(&state, ci.instr, ci.hit);
            const rd_val = plan_mod.resolveMemAndAdvanceSpills(&regs, &spills, eff);
            const rdefs = try self.recordUses(eff.uses_mask, insn_idx);

            self.insn_flows[insn_idx] = .{
                .insn_idx = insn_idx,
                .block_id = blk.id,
                .address = ci.instr.address,
                .uses_mask = eff.uses_mask,
                .defs_mask = eff.defs_mask,
                .primary_rd = eff.primary_rd,
                .primary_val = rd_val,
                .cond_active = active_cond,
                .reg_defs = rdefs,
            };

            try self.recordSiteExtras(eff, flags, &regs, blk, local_idx, insn_idx, ci.instr.address);
            plan_mod.applyEffects(self.plan, insn_idx, ci.instr.address, eff, rd_val, &self.cur_defs, &regs, &flags);
            plan_mod.advanceIt(&cur_it, ci.hit.group, ci.instr.hw1, in_it);
        }
        if (blk.summary.kind == .ret) {
            self.ret_kind = mergeReturnKind(self.ret_kind, &self.cur_defs, &regs);
        }
    }

    fn recordSiteExtras(
        self: *Collector,
        eff: effects.Effect,
        flags: value.FlagState,
        regs: *const [16]value.Value,
        blk: cfg_mod.BasicBlock,
        local_idx: usize,
        insn_idx: InsnIndex,
        addr: u32,
    ) !void {
        if (eff.consumes_cond) |c| {
            const origin: ?value.FlagOrigin = if (eff.self_cond_reg == null and flags == .known) flags.known else null;
            try self.cond_pairs.append(self.aa, .{
                .consumer_insn = insn_idx,
                .consumer_addr = addr,
                .cond = c,
                .origin = origin,
                .self_reg = eff.self_cond_reg,
            });
        }
        if (eff.pair) |p| try self.pairs.append(self.aa, p);
        self.saved_callee |= eff.pushed_mask & (aapcs.callee_saved_mask | (@as(u16, 1) << 14));
        if (local_idx + 1 == blk.insns.len) {
            for (blk.succs) |edge| {
                if (edge.kind != .call and edge.kind != .indirect_call and edge.kind != .tail_call) continue;
                try self.calls.append(self.aa, .{
                    .insn_idx = insn_idx,
                    .address = addr,
                    .kind = edge.kind,
                    .target_address = edge.target_address,
                    .target_name = if (edge.target_name) |n| try self.aa.dupe(u8, n) else null,
                    .args = aapcs.captureArgs(regs),
                });
            }
        }
    }

    fn recordUses(self: *Collector, uses_mask: u16, insn_idx: InsnIndex) ![]const RegUseDefs {
        const count = @popCount(uses_mask);
        if (count == 0) return &.{};
        const out = try self.aa.alloc(RegUseDefs, count);
        var out_i: usize = 0;
        var rem = uses_mask;
        while (rem != 0) : (out_i += 1) {
            const r: u4 = @intCast(@ctz(rem));
            var d_list: std.ArrayListUnmanaged(DefId) = .empty;
            for (self.plan.reg_defs[r].items) |d| {
                if (!self.cur_defs.isSet(d)) continue;
                try d_list.append(self.aa, d);
                try appendUniqueInsn(&self.use_lists[d], self.scratch, insn_idx);
            }
            out[out_i] = .{ .reg = r, .defs = try d_list.toOwnedSlice(self.aa) };
            rem &= rem - 1;
        }
        return out;
    }
};

fn collectResults(
    arena_in: std.heap.ArenaAllocator,
    scratch: std.mem.Allocator,
    cfg: *const cfg_mod.Cfg,
    plan: *const plan_mod.Plan,
    opts: Options,
    states: []const plan_mod.BlockState,
    converged: bool,
) !Dataflow {
    var arena = arena_in;
    const aa = arena.allocator();
    const use_lists = try scratch.alloc(std.ArrayListUnmanaged(InsnIndex), plan.defs.items.len);
    defer {
        for (use_lists) |*l| {
            l.deinit(scratch);
        }
        scratch.free(use_lists);
    }
    @memset(use_lists, .empty);

    var collector: Collector = .{
        .aa = aa,
        .scratch = scratch,
        .plan = plan,
        .target_bus = opts.bus,
        .insn_flows = try aa.alloc(InsnFlow, plan.total_insns),
        .use_lists = use_lists,
        .cur_defs = try std.DynamicBitSetUnmanaged.initEmpty(scratch, plan.defs.items.len),
    };
    defer collector.cur_defs.deinit(scratch);

    for (cfg.blocks, 0..) |blk, b_idx| {
        try collector.visitBlock(blk, states[b_idx]);
    }

    const out_uses = try aa.alloc([]const InsnIndex, plan.defs.items.len);
    for (use_lists, 0..) |list, i| {
        out_uses[i] = try aa.dupe(InsnIndex, list.items);
    }
    var used_args: u4 = 0;
    var arg_i: u3 = 0;
    while (arg_i < 4) : (arg_i += 1) {
        if (use_lists[arg_i].items.len > 0) used_args |= @as(u4, 1) << @intCast(arg_i);
    }
    const out_defs = try aa.dupe(DefSite, plan.defs.items);
    const out_cond_pairs = try collector.cond_pairs.toOwnedSlice(aa);
    const out_calls = try collector.calls.toOwnedSlice(aa);
    const out_pairs = try collector.pairs.toOwnedSlice(aa);

    return .{
        .arena = arena,
        .insns = collector.insn_flows,
        .defs = out_defs,
        .def_uses = out_uses,
        .cond_pairs = out_cond_pairs,
        .calls = out_calls,
        .pairs = out_pairs,
        .signature = .{
            .used_args_mask = used_args,
            .saved_callee_mask = collector.saved_callee,
            .return_kind = collector.ret_kind,
        },
        .converged = converged,
    };
}

fn mergeReturnKind(
    cur: aapcs.ReturnKind,
    defs_set: *const std.DynamicBitSetUnmanaged,
    regs: *const [16]value.Value,
) aapcs.ReturnKind {
    if (cur == .r0_r1_pair) return .r0_r1_pair;
    const r0_defined = !defs_set.isSet(0) or regs[0] != .entry_reg;
    const next = aapcs.inferReturnKind(r0_defined, regs[0], regs[1]);
    if (next == .r0_r1_pair) return .r0_r1_pair;
    if (next == .r0 or cur == .r0) return .r0;
    return .none;
}

fn appendUniqueInsn(list: *std.ArrayListUnmanaged(InsnIndex), allocator: std.mem.Allocator, val: InsnIndex) !void {
    if (list.items.len > 0 and list.items[list.items.len - 1] == val) return;
    try list.append(allocator, val);
}
