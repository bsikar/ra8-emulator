//! Structured pseudocode-lite per-function and per-line emitter (RA8EMU-1355).
const std = @import("std");

const cfg_mod = @import("cfg.zig");
const dataflow_mod = @import("dataflow.zig");
const elf = @import("ra8_board").image.elf;
const emit_expr = @import("emit_expr.zig");
const emit_format = @import("emit_format.zig");
const text_disasm = @import("ra8_chip").core.cpu.text.disasm;
const value = @import("value.zig");

/// Options configuring `emitFunction`.
pub const Options = struct {
    image: ?elf.Image = null,
};

/// Pseudocode-lite annotation attached to a single instruction address inside a function.
pub const LineEmit = struct {
    address: u32,
    block_id: cfg_mod.BlockId,
    is_block_leader: bool,
    label: []const u8,
    pseudo: []const u8,
};

/// Arena-backed emitted pseudocode-lite for one reconstructed function `Cfg`.
pub const FunctionEmit = struct {
    arena: std.heap.ArenaAllocator,
    entry: u32,
    name: []const u8,
    signature_line: []const u8,
    lines: []const LineEmit,

    pub fn deinit(self: *FunctionEmit) void {
        self.arena.deinit();
    }

    /// Binary-search the emitted line record for normalized `address`.
    pub fn lineAt(self: *const FunctionEmit, address: u32) ?*const LineEmit {
        const norm = address & ~@as(u32, 1);
        var low: usize = 0;
        var high: usize = self.lines.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.lines[mid].address < norm) {
                low = mid + 1;
            } else if (self.lines[mid].address > norm) {
                high = mid;
            } else {
                return &self.lines[mid];
            }
        }
        return null;
    }

    /// Return the emitted pseudocode-lite string for `address`, if present.
    pub fn pseudoAt(self: *const FunctionEmit, address: u32) ?[]const u8 {
        const entry = self.lineAt(address) orelse return null;
        return entry.pseudo;
    }
};

const EmitContext = struct {
    aa: std.mem.Allocator,
    cfg: *const cfg_mod.Cfg,
    df: *const dataflow_mod.Dataflow,
    image: ?elf.Image,
    cond_for_insn: []const ?usize,
    call_for_insn: []const ?usize,
    call_arities: []const u3,
    call_ret_used: []const bool,
};

/// Emit structured pseudocode-lite lines for every instruction in `cfg` ordered by address.
pub fn emitFunction(
    allocator: std.mem.Allocator,
    cfg: *const cfg_mod.Cfg,
    df: *const dataflow_mod.Dataflow,
    opts: Options,
) !FunctionEmit {
    const cond_for_insn = try allocator.alloc(?usize, df.insns.len);
    defer allocator.free(cond_for_insn);
    @memset(cond_for_insn, null);
    for (df.cond_pairs, 0..) |cp, idx| {
        if (cp.consumer_insn < cond_for_insn.len) cond_for_insn[cp.consumer_insn] = idx;
    }

    const call_for_insn = try allocator.alloc(?usize, df.insns.len);
    defer allocator.free(call_for_insn);
    @memset(call_for_insn, null);
    for (df.calls, 0..) |c, idx| {
        if (c.insn_idx < call_for_insn.len) call_for_insn[c.insn_idx] = idx;
    }

    const call_arities = try emit_format.computeCallArities(allocator, cfg, df);
    defer allocator.free(call_arities);
    const call_ret_used = try emit_format.computeCallRetUsed(allocator, cfg, df, call_arities);
    defer allocator.free(call_ret_used);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const fn_name = if (cfg.name) |n|
        try aa.dupe(u8, n)
    else
        try std.fmt.allocPrint(aa, "fn_{x:0>8}", .{cfg.entry});
    const sig_line = try emit_format.formatSignature(aa, fn_name, df.signature);

    const ctx: EmitContext = .{
        .aa = aa,
        .cfg = cfg,
        .df = df,
        .image = opts.image,
        .cond_for_insn = cond_for_insn,
        .call_for_insn = call_for_insn,
        .call_arities = call_arities,
        .call_ret_used = call_ret_used,
    };
    const out_lines = try emitAllLines(&ctx);

    return .{
        .arena = arena,
        .entry = cfg.entry,
        .name = fn_name,
        .signature_line = sig_line,
        .lines = out_lines,
    };
}

fn emitAllLines(ctx: *const EmitContext) ![]const LineEmit {
    var list: std.ArrayListUnmanaged(LineEmit) = .empty;
    var buf: [512]u8 = undefined;
    var label_buf: [128]u8 = undefined;

    for (ctx.cfg.blocks) |blk| {
        const leader_label = if (blk.id > 0 and blk.preds.len > 0) blk: {
            var lw: std.Io.Writer = .fixed(&label_buf);
            try emit_format.writeTargetLabel(&lw, ctx.image, ctx.cfg, blk.start);
            break :blk try ctx.aa.dupe(u8, lw.buffered());
        } else "";

        for (blk.insns, 0..) |ci, local_idx| {
            const addr = ci.instr.address & ~@as(u32, 1);
            var w: std.Io.Writer = .fixed(&buf);
            try formatInsnLine(ctx, blk, local_idx, ci, &w);
            try list.append(ctx.aa, .{
                .address = addr,
                .block_id = blk.id,
                .is_block_leader = local_idx == 0 and blk.preds.len > 0,
                .label = if (local_idx == 0) leader_label else "",
                .pseudo = try ctx.aa.dupe(u8, w.buffered()),
            });
        }
    }

    std.sort.pdq(LineEmit, list.items, {}, struct {
        fn lessThan(_: void, a: LineEmit, b: LineEmit) bool {
            return a.address < b.address;
        }
    }.lessThan);
    return list.toOwnedSlice(ctx.aa);
}

fn formatInsnLine(
    ctx: *const EmitContext,
    blk: cfg_mod.BasicBlock,
    local_idx: usize,
    ci: cfg_mod.Insn,
    w: *std.Io.Writer,
) !void {
    const flow = ctx.df.insnAt(ci.instr.address);
    if (std.mem.eql(u8, ci.hit.group, "it")) {
        const dis = text_disasm.one(ci.instr);
        if (dis) |d| return w.print("/* {s} */", .{d.slice()});
        return w.writeAll("/* predication */");
    }

    const cond_opt = findCondPair(ctx, flow);
    const is_last = local_idx + 1 == blk.insns.len;
    try maybeWriteItPrefix(ctx, flow, cond_opt, is_last, blk.summary.kind, w);

    if (is_last and blk.summary.kind != .fallthrough and blk.summary.kind != .it_block) {
        if (try tryWriteTerminator(ctx, blk, flow, cond_opt, w)) return;
    }

    const dis_text = text_disasm.one(ci.instr);
    const dis_line = if (dis_text) |*d| d.slice() else "";
    if (flow) |fl| {
        const pair_opt = findPairAt(ctx.df.pairs, ci.instr.address);
        try emit_expr.writeInstruction(w, ctx.image, ci.instr.address, dis_line, fl, pair_opt, cond_opt);
    } else {
        try w.print("/* {s} */", .{dis_line});
    }
}

fn maybeWriteItPrefix(
    ctx: *const EmitContext,
    flow_opt: ?*const dataflow_mod.InsnFlow,
    cond_opt: ?value.ConditionPair,
    is_last: bool,
    blk_kind: anytype,
    w: *std.Io.Writer,
) !void {
    const fl = flow_opt orelse return;
    if (fl.cond_active == null or (is_last and blk_kind == .cond_branch)) return;
    const cp = cond_opt orelse return;
    try w.writeAll("if (");
    try emit_format.writeCondition(w, ctx.image, cp.cond, cp.origin, cp.self_reg);
    try w.writeAll(") ");
}

fn findCondPair(ctx: *const EmitContext, flow_opt: ?*const dataflow_mod.InsnFlow) ?value.ConditionPair {
    const fl = flow_opt orelse return null;
    if (fl.insn_idx >= ctx.cond_for_insn.len) return null;
    const cp_i = ctx.cond_for_insn[fl.insn_idx] orelse return null;
    return ctx.df.cond_pairs[cp_i];
}

fn tryWriteTerminator(
    ctx: *const EmitContext,
    blk: cfg_mod.BasicBlock,
    flow_opt: ?*const dataflow_mod.InsnFlow,
    cond_opt: ?value.ConditionPair,
    w: *std.Io.Writer,
) !bool {
    switch (blk.summary.kind) {
        .call, .indirect_call => return tryWriteCallTerminator(ctx, flow_opt, w),
        .ret => {
            try writeReturnStmt(ctx, blk, w);
            return true;
        },
        .cond_branch => return tryWriteCondBranch(ctx, blk, cond_opt, w),
        .branch => {
            if (blk.succs.len > 0 and blk.succs[0].kind == .tail_call) {
                return tryWriteCallTerminator(ctx, flow_opt, w);
            }
            return tryWriteDirectJump(ctx, blk, w);
        },
        .indirect_jump => return tryWriteUnresolvedJump(blk, w),
        .svc => {
            try w.writeAll("svc()");
            return true;
        },
        .halt => {
            try w.writeAll("halt()");
            return true;
        },
        .fallthrough, .it_block => return false,
    }
}

fn tryWriteCallTerminator(
    ctx: *const EmitContext,
    flow_opt: ?*const dataflow_mod.InsnFlow,
    w: *std.Io.Writer,
) !bool {
    const fl = flow_opt orelse return false;
    if (fl.insn_idx >= ctx.call_for_insn.len) return false;
    const c_idx = ctx.call_for_insn[fl.insn_idx] orelse return false;
    const call = ctx.df.calls[c_idx];

    if (call.kind == .tail_call) {
        if (ctx.df.signature.return_kind != .none) try w.writeAll("return ");
    } else if (ctx.call_ret_used[c_idx]) {
        try w.writeAll("r0 = ");
    }

    if (call.kind == .indirect_call) {
        try w.writeAll("(*fn_ptr)");
    } else if (call.target_name) |name| {
        try w.writeAll(name);
    } else if (call.target_address) |addr| {
        try emit_format.writeTargetLabel(w, ctx.image, ctx.cfg, addr);
    } else {
        try w.writeAll("sub_unknown");
    }

    try w.writeByte('(');
    const arity = ctx.call_arities[c_idx];
    var i: usize = 0;
    while (i < arity) : (i += 1) {
        if (i > 0) try w.writeAll(", ");
        try emit_format.writeValue(w, ctx.image, call.args[i], @intCast(i));
    }
    try w.writeByte(')');
    return true;
}

fn writeReturnStmt(ctx: *const EmitContext, blk: cfg_mod.BasicBlock, w: *std.Io.Writer) !void {
    switch (ctx.df.signature.return_kind) {
        .none => return w.writeAll("return"),
        .r0_r1_pair => return w.writeAll("return r1:r0"),
        .r0 => {
            if (recentR0Constant(ctx.df, blk)) |c| {
                try w.writeAll("return ");
                return emit_format.writeConstant(w, ctx.image, c, true);
            }
            return w.writeAll("return r0");
        },
    }
}

fn recentR0Constant(df: *const dataflow_mod.Dataflow, blk: cfg_mod.BasicBlock) ?u32 {
    if (blk.insns.len < 2) return null;
    var idx: usize = blk.insns.len - 1;
    while (idx > 0) {
        idx -= 1;
        const fl = df.insnAt(blk.insns[idx].instr.address) orelse continue;
        if ((fl.defs_mask & 1) != 0) {
            if (fl.primary_rd == @as(?u4, 0)) return fl.primary_val.asConstant();
            return null;
        }
    }
    return null;
}

fn tryWriteCondBranch(
    ctx: *const EmitContext,
    blk: cfg_mod.BasicBlock,
    cond_opt: ?value.ConditionPair,
    w: *std.Io.Writer,
) !bool {
    const taken = findSucc(blk.succs, .branch_taken) orelse return false;
    const dst = taken.target_address orelse return false;
    try w.writeAll("if (");
    if (cond_opt) |cp| {
        try emit_format.writeCondition(w, ctx.image, cp.cond, cp.origin, cp.self_reg);
    } else {
        try w.writeAll("cond");
    }
    try w.writeAll(") goto ");
    try emit_format.writeTargetLabel(w, ctx.image, ctx.cfg, dst);
    return true;
}

fn tryWriteDirectJump(ctx: *const EmitContext, blk: cfg_mod.BasicBlock, w: *std.Io.Writer) !bool {
    const edge = if (blk.succs.len > 0) blk.succs[0] else return false;
    const dst = edge.target_address orelse return false;
    try w.writeAll("goto ");
    try emit_format.writeTargetLabel(w, ctx.image, ctx.cfg, dst);
    return true;
}

fn tryWriteUnresolvedJump(blk: cfg_mod.BasicBlock, w: *std.Io.Writer) !bool {
    const edge = if (blk.succs.len > 0) blk.succs[0] else return false;
    const reason = if (edge.unresolved) |r| @tagName(r) else "computed";
    try w.print("goto *(...) /* unresolved: {s} */", .{reason});
    return true;
}

fn findSucc(succs: []const cfg_mod.Edge, kind: cfg_mod.EdgeKind) ?cfg_mod.Edge {
    for (succs) |edge| {
        if (edge.kind == kind) return edge;
    }
    return null;
}

fn findPairAt(pairs: []const value.RegPair, addr: u32) ?value.RegPair {
    const norm = addr & ~@as(u32, 1);
    for (pairs) |p| {
        if ((p.def_address & ~@as(u32, 1)) == norm) return p;
    }
    return null;
}
