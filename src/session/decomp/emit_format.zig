//! Pseudocode-lite formatting primitives, condition rendering, and ABI call-site helpers (RA8EMU-1355).
const std = @import("std");

const aapcs = @import("aapcs.zig");
const annotate = @import("../annotate.zig");
const annotation_names = @import("../annotation_names.zig");
const cfg_mod = @import("cfg.zig");
const dataflow_mod = @import("dataflow.zig");
const dwarf = @import("../dwarf/dwarf.zig");
const elf = @import("ra8_board").image.elf;
const symbols = @import("../symbols.zig");
const text = @import("ra8_chip").core.cpu.text.text;
const value = @import("value.zig");

/// Parse a UAL disassembly line into cleaned mnemonic (`add.w` -> `add`) and comma-split operands.
pub const ParsedDisasm = struct {
    raw_mnemonic: []const u8,
    mnemonic: []const u8,
    args_str: []const u8,
    ops_buf: [6][]const u8 = @splat(""),
    ops_len: usize = 0,

    pub fn ops(self: *const ParsedDisasm) []const []const u8 {
        return self.ops_buf[0..self.ops_len];
    }

    pub fn parse(line: []const u8) ParsedDisasm {
        const trimmed = std.mem.trim(u8, line, " \t");
        const space = std.mem.indexOfScalar(u8, trimmed, ' ');
        const raw_mnem = if (space) |sp| trimmed[0..sp] else trimmed;
        const mnem = stripWidthSuffix(raw_mnem);
        const args = if (space) |sp| std.mem.trim(u8, trimmed[sp + 1 ..], " \t") else "";
        var out: ParsedDisasm = .{ .raw_mnemonic = raw_mnem, .mnemonic = mnem, .args_str = args };
        splitOperands(args, &out);
        return out;
    }
};

fn stripWidthSuffix(mnem: []const u8) []const u8 {
    if (std.mem.endsWith(u8, mnem, ".w") or std.mem.endsWith(u8, mnem, ".n")) {
        return mnem[0 .. mnem.len - 2];
    }
    return mnem;
}

fn splitOperands(args: []const u8, out: *ParsedDisasm) void {
    if (args.len == 0) return;
    var depth: usize = 0;
    var start: usize = 0;
    for (args, 0..) |ch, i| {
        depth = updateDepth(depth, ch);
        if (ch == ',' and depth == 0) {
            appendTrimmedOp(args[start..i], out);
            start = i + 1;
        }
    }
    appendTrimmedOp(args[start..], out);
}

fn updateDepth(depth: usize, ch: u8) usize {
    if (ch == '[' or ch == '{') return depth + 1;
    if ((ch == ']' or ch == '}') and depth > 0) return depth - 1;
    return depth;
}

fn appendTrimmedOp(raw: []const u8, out: *ParsedDisasm) void {
    if (out.ops_len >= out.ops_buf.len) return;
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return;
    out.ops_buf[out.ops_len] = trimmed;
    out.ops_len += 1;
}

/// Resolve an exact symbol, global/static local, or named chip register for `val`.
pub fn resolveAddressName(image: ?elf.Image, val: u32) ?[]const u8 {
    if (val < 0x100) return null;
    if (image) |img| {
        if (annotate.symbolAt(img, val)) |name| return name;
        if (dwarf.locals.atAddress(dwarf.locals.ofImage(img), val) catch null) |local_name| {
            return local_name;
        }
    }
    return annotation_names.find(val);
}

/// Write a decimal/hex constant, optionally annotated with a resolved ELF/peripheral symbol comment.
pub fn writeConstant(w: *std.Io.Writer, image: ?elf.Image, val: u32, with_comment: bool) !void {
    if (val < text.decimal_below) {
        try w.print("{d}", .{val});
    } else {
        try w.print("0x{x}", .{val});
    }
    if (with_comment) {
        if (resolveAddressName(image, val)) |name| {
            try w.print(" /* {s} */", .{name});
        }
    }
}

/// Write a symbolic intra-function (`fn+0xoff`), external symbol, or `loc_<addr>` label.
pub fn writeTargetLabel(w: *std.Io.Writer, image: ?elf.Image, cfg: *const cfg_mod.Cfg, target_addr: u32) !void {
    const norm = target_addr & ~@as(u32, 1);
    const fn_end = cfg.entry +% cfg.extent_size;
    if ((cfg.extent_size > 0 and norm >= cfg.entry and norm < fn_end) or cfg.blockAt(norm) != null) {
        return writeInternalLabel(w, cfg, norm);
    }
    if (image) |img| {
        if (try tryWriteExternalSymbol(w, img, norm)) return;
    }
    try w.print("loc_{x:0>8}", .{norm});
}

fn writeInternalLabel(w: *std.Io.Writer, cfg: *const cfg_mod.Cfg, norm: u32) !void {
    const base = cfg.name orelse "";
    if (base.len > 0 and norm == cfg.entry) return w.print("{s}", .{base});
    if (base.len > 0 and norm > cfg.entry) return w.print("{s}+0x{x}", .{ base, norm - cfg.entry });
    return w.print("loc_{x:0>8}", .{norm});
}

fn tryWriteExternalSymbol(w: *std.Io.Writer, img: elf.Image, norm: u32) !bool {
    if (annotate.symbolAt(img, norm)) |sym| {
        try w.print("{s}", .{sym});
        return true;
    }
    if (symbols.inside(img, norm)) |site| {
        if (site.offset == 0) {
            try w.print("{s}", .{site.name});
        } else {
            try w.print("{s}+0x{x}", .{ site.name, site.offset });
        }
        return true;
    }
    return false;
}

/// Format an abstract dataflow `Value` or fall back to register name `fallback_reg`.
pub fn writeValue(w: *std.Io.Writer, image: ?elf.Image, val: value.Value, fallback_reg: ?u4) !void {
    switch (val) {
        .constant => |c| try writeConstant(w, image, c, true),
        .sp_offset => |off| try writeSpOffset(w, off),
        .entry_reg => |r| try w.writeAll(text.names[r]),
        .pair_lo => |p| try w.print("{s}:{s}", .{ text.names[p.hi_reg], text.names[p.lo_reg] }),
        .pair_hi => |p| try w.print("hi({s}:{s})", .{ text.names[p.hi_reg], text.names[p.lo_reg] }),
        else => {
            if (fallback_reg) |r| {
                try w.writeAll(text.names[r]);
            } else {
                try w.writeAll("?");
            }
        },
    }
}

fn writeSpOffset(w: *std.Io.Writer, off: i32) !void {
    if (off == 0) {
        try w.writeAll("sp");
    } else if (off > 0) {
        try w.print("sp + 0x{x}", .{@as(u32, @intCast(off))});
    } else {
        const mag = 0 -% @as(u32, @bitCast(off));
        try w.print("sp - 0x{x}", .{mag});
    }
}

/// Emit a relational/bitwise condition predicate from a paired flag setter or self-comparing branch.
pub fn writeCondition(
    w: *std.Io.Writer,
    image: ?elf.Image,
    cond: u4,
    origin_opt: ?value.FlagOrigin,
    self_reg: ?u4,
) !void {
    if (self_reg) |r| {
        const rel = if (cond == 0) "==" else "!=";
        return w.print("{s} {s} 0", .{ text.names[r], rel });
    }
    const origin = origin_opt orelse return writeFallbackCond(w, cond);
    if (cond >= 14) return w.writeAll("true");
    switch (origin.kind) {
        .cmp => try writeCmpCondition(w, image, origin, cond),
        .cmn => try writeCmnCondition(w, origin, cond),
        .tst => try writeBitCondition(w, origin, cond, "&"),
        .teq => try writeBitCondition(w, origin, cond, "^"),
        .result_flags => try writeResultCondition(w, origin, cond),
    }
}

fn writeFallbackCond(w: *std.Io.Writer, cond: u4) !void {
    const suffix = if (cond < text.conds.len) text.conds[cond] else "al";
    try w.print("cond_{s}", .{suffix});
}

fn condOp(cond: u4) ?[]const u8 {
    return switch (cond) {
        0 => "==",
        1 => "!=",
        2, 10 => ">=",
        3, 11 => "<",
        8, 12 => ">",
        9, 13 => "<=",
        else => null,
    };
}

fn writeCmpCondition(w: *std.Io.Writer, image: ?elf.Image, origin: value.FlagOrigin, cond: u4) !void {
    const op = condOp(cond) orelse return writeFallbackCond(w, cond);
    try writeOriginLhs(w, origin);
    try w.print(" {s} ", .{op});
    try writeOriginRhs(w, image, origin);
}

fn writeCmnCondition(w: *std.Io.Writer, origin: value.FlagOrigin, cond: u4) !void {
    const rel = if (cond == 0) "==" else if (cond == 1) "!=" else return writeFallbackCond(w, cond);
    try w.writeByte('(');
    try writeOriginLhs(w, origin);
    try w.writeAll(" + ");
    try writeOriginRhs(w, null, origin);
    try w.print(") {s} 0", .{rel});
}

fn writeBitCondition(w: *std.Io.Writer, origin: value.FlagOrigin, cond: u4, bit_op: []const u8) !void {
    if (cond != 0 and cond != 1) return writeFallbackCond(w, cond);
    const rel = if (cond == 0) "==" else "!=";
    try w.writeByte('(');
    try writeOriginLhs(w, origin);
    try w.print(" {s} ", .{bit_op});
    try writeOriginRhs(w, null, origin);
    try w.print(") {s} 0", .{rel});
}

fn writeResultCondition(w: *std.Io.Writer, origin: value.FlagOrigin, cond: u4) !void {
    const rel: []const u8 = switch (cond) {
        0 => "== 0",
        1 => "!= 0",
        4 => "< 0",
        5 => ">= 0",
        else => return writeFallbackCond(w, cond),
    };
    try writeOriginLhs(w, origin);
    try w.print(" {s}", .{rel});
}

fn writeOriginLhs(w: *std.Io.Writer, origin: value.FlagOrigin) !void {
    if (origin.lhs_reg) |r| return w.writeAll(text.names[r]);
    if (origin.lhs_val.asConstant()) |c| return writeConstant(w, null, c, false);
    try w.writeAll("lhs");
}

fn writeOriginRhs(w: *std.Io.Writer, image: ?elf.Image, origin: value.FlagOrigin) !void {
    if (origin.rhs_imm) |imm| return writeConstant(w, image, imm, false);
    if (origin.rhs_reg) |r| return w.writeAll(text.names[r]);
    if (origin.rhs_val.asConstant()) |c| return writeConstant(w, image, c, false);
    try w.writeAll("rhs");
}

/// Format an AAPCS32 signature prototype line using inferred return kind and used arguments.
pub fn formatSignature(aa: std.mem.Allocator, fn_name: []const u8, sig: aapcs.SignatureSummary) ![]const u8 {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ret_str = switch (sig.return_kind) {
        .none => "void",
        .r0 => "r0",
        .r0_r1_pair => "r1:r0",
    };
    try w.print("{s} {s}(", .{ ret_str, fn_name });
    const count: usize = if (sig.used_args_mask == 0) 0 else @as(usize, 4 - @clz(sig.used_args_mask));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(text.names[i]);
    }
    try w.writeByte(')');
    return aa.dupe(u8, w.buffered());
}

/// Infer AAPCS32 argument counts (`0..4`) for each call site using unconsumed in-block defs.
pub fn computeCallArities(
    allocator: std.mem.Allocator,
    cfg: *const cfg_mod.Cfg,
    df: *const dataflow_mod.Dataflow,
) ![]u3 {
    const arities = try allocator.alloc(u3, df.calls.len);
    for (df.calls, 0..) |call, c_idx| {
        arities[c_idx] = inferCallArity(cfg, df, call);
    }
    return arities;
}

fn inferCallArity(cfg: *const cfg_mod.Cfg, df: *const dataflow_mod.Dataflow, call: aapcs.CallSite) u3 {
    const blk_id = if (call.insn_idx < df.insns.len) df.insns[call.insn_idx].block_id else return 0;
    const blk = cfg.blockById(blk_id) orelse return 0;
    const prepared_mask = blockPreparedArgMask(df, blk, call.insn_idx);
    if (prepared_mask != 0) return @intCast(4 - @clz(prepared_mask));
    if (call.kind == .tail_call and df.signature.used_args_mask != 0) {
        return @intCast(4 - @clz(df.signature.used_args_mask));
    }
    return 0;
}

fn blockPreparedArgMask(df: *const dataflow_mod.Dataflow, blk: *const cfg_mod.BasicBlock, call_insn: u32) u4 {
    var mask: u4 = 0;
    for (blk.insns) |ci| {
        const fl = df.insnAt(ci.instr.address) orelse continue;
        if (fl.insn_idx >= call_insn) break;
        mask |= unconsumedInMask(df, fl.insn_idx, @truncate(fl.defs_mask & aapcs.arg_mask));
    }
    return mask;
}

fn unconsumedInMask(df: *const dataflow_mod.Dataflow, insn_idx: u32, arg_defs: u4) u4 {
    var out: u4 = 0;
    var r: u3 = 0;
    while (r < 4) : (r += 1) {
        const bit: u4 = @as(u4, 1) << @intCast(r);
        if ((arg_defs & bit) != 0 and isDefUnconsumed(df, insn_idx, @intCast(r))) out |= bit;
    }
    return out;
}

fn isDefUnconsumed(df: *const dataflow_mod.Dataflow, insn_idx: dataflow_mod.InsnIndex, reg: u4) bool {
    for (df.defs) |d| {
        if (d.insn_idx == insn_idx and d.kind == .insn and d.reg == reg) {
            return df.def_uses[d.id].len == 0;
        }
    }
    return false;
}

/// Determine whether each call site's `r0` return value has any consumer or is forwarded into a return/call.
pub fn computeCallRetUsed(
    allocator: std.mem.Allocator,
    cfg: *const cfg_mod.Cfg,
    df: *const dataflow_mod.Dataflow,
    call_arities: []const u3,
) ![]bool {
    const used = try allocator.alloc(bool, df.calls.len);
    for (df.calls, 0..) |call, c_idx| {
        used[c_idx] = isCallRetUsed(cfg, df, call, call_arities);
    }
    return used;
}

fn isCallRetUsed(
    cfg: *const cfg_mod.Cfg,
    df: *const dataflow_mod.Dataflow,
    call: aapcs.CallSite,
    call_arities: []const u3,
) bool {
    if (call.kind == .tail_call) return false;
    for (df.defs) |d| {
        if (d.insn_idx == call.insn_idx and d.kind == .call_ret and d.reg == 0) {
            if (df.def_uses[d.id].len > 0) return true;
            break;
        }
    }
    if (passesCallResultToNextCall(df, call, call_arities)) return true;
    return forwardsCallResultToRet(cfg, df, call);
}

fn passesCallResultToNextCall(df: *const dataflow_mod.Dataflow, call: aapcs.CallSite, call_arities: []const u3) bool {
    for (df.calls, 0..) |other, o_idx| {
        if (other.insn_idx == call.insn_idx) continue;
        const arity = call_arities[o_idx];
        var k: usize = 0;
        while (k < arity) : (k += 1) {
            if (other.args[k] == .call_result and other.args[k].call_result == call.address) return true;
        }
    }
    return false;
}

fn forwardsCallResultToRet(cfg: *const cfg_mod.Cfg, df: *const dataflow_mod.Dataflow, call: aapcs.CallSite) bool {
    if (call.insn_idx >= df.insns.len or df.signature.return_kind == .none) return false;
    const call_blk = cfg.blockById(df.insns[call.insn_idx].block_id) orelse return false;
    for (call_blk.succs) |edge| {
        if (edge.kind != .fallthrough) continue;
        const next_id = edge.target_block orelse continue;
        const next_blk = cfg.blockById(next_id) orelse continue;
        if (next_blk.summary.kind != .ret or next_blk.preds.len != 1) continue;
        for (next_blk.insns) |ci| {
            const fl = df.insnAt(ci.instr.address) orelse continue;
            if ((fl.defs_mask & 1) != 0) return false;
        }
        return true;
    }
    return false;
}
