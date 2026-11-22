//! Pseudocode-lite statement formatting for non-branch/non-call instructions (RA8EMU-1355).
const std = @import("std");

const annotation_locals = @import("../annotation_locals.zig");
const dataflow_mod = @import("dataflow.zig");
const elf = @import("ra8_board").image.elf;
const emit_format = @import("emit_format.zig");
const text = @import("ra8_chip").core.cpu.text.text;
const value = @import("value.zig");

const ParsedDisasm = emit_format.ParsedDisasm;

/// Emit pseudocode-lite for one non-branch/non-call instruction line.
pub fn writeInstruction(
    w: *std.Io.Writer,
    image: ?elf.Image,
    addr: u32,
    dis_line: []const u8,
    flow: *const dataflow_mod.InsnFlow,
    pair_opt: ?value.RegPair,
    cond_opt: ?value.ConditionPair,
) !void {
    const parsed = ParsedDisasm.parse(dis_line);
    const m = parsed.mnemonic;
    const ops = parsed.ops();

    if (std.mem.eql(u8, m, "push")) return w.print("save({s})", .{parsed.args_str});
    if (std.mem.eql(u8, m, "pop")) return w.print("restore({s})", .{parsed.args_str});
    if (isBarrierOrHint(m)) return w.print("{s}()", .{m});
    if (isFlagSetter(m) and ops.len >= 2) return writeFlagSetter(w, m, ops);
    if (try tryWritePair(w, m, ops, pair_opt)) return;
    if (isLoadMnemonic(m) or isStoreMnemonic(m)) {
        try writeMemOp(w, image, addr, dis_line, &parsed, flow);
        return;
    }
    if (try tryWriteCsel(w, image, m, ops, cond_opt)) return;
    try writeAluOrMove(w, image, &parsed, flow);
}

fn isBarrierOrHint(m: []const u8) bool {
    return std.mem.eql(u8, m, "nop") or std.mem.eql(u8, m, "wfi") or
        std.mem.eql(u8, m, "wfe") or std.mem.eql(u8, m, "sev") or
        std.mem.eql(u8, m, "dsb") or std.mem.eql(u8, m, "dmb") or
        std.mem.eql(u8, m, "isb") or std.mem.eql(u8, m, "yield");
}

fn isFlagSetter(m: []const u8) bool {
    return std.mem.eql(u8, m, "cmp") or std.mem.eql(u8, m, "cmn") or
        std.mem.eql(u8, m, "tst") or std.mem.eql(u8, m, "teq");
}

fn writeFlagSetter(w: *std.Io.Writer, m: []const u8, ops: []const []const u8) !void {
    try w.print("flags = {s}({s}, {s})", .{ m, ops[0], cleanImm(ops[1]) });
}

fn tryWritePair(
    w: *std.Io.Writer,
    m: []const u8,
    ops: []const []const u8,
    pair_opt: ?value.RegPair,
) !bool {
    const p = pair_opt orelse return false;
    if (inList(&.{ "umull", "smull", "umlal", "smlal" }, m) and ops.len >= 4) {
        const is_acc = std.mem.eql(u8, m, "umlal") or std.mem.eql(u8, m, "smlal");
        const op_str = if (is_acc) "+=" else "=";
        try w.print("{s}:{s} {s} {s} * {s}", .{
            text.names[p.hi_reg], text.names[p.lo_reg], op_str, ops[2], ops[3],
        });
        return true;
    }
    if (std.mem.eql(u8, m, "ldrd") and ops.len >= 3) {
        try w.print("{s}:{s} = mem64[{s}]", .{
            text.names[p.hi_reg], text.names[p.lo_reg], stripBrackets(ops[2]),
        });
        return true;
    }
    return false;
}

fn isLoadMnemonic(m: []const u8) bool {
    return std.mem.startsWith(u8, m, "ldr") or std.mem.eql(u8, m, "ldm") or std.mem.eql(u8, m, "ldmia");
}

fn isStoreMnemonic(m: []const u8) bool {
    return std.mem.startsWith(u8, m, "str") or std.mem.eql(u8, m, "stm") or std.mem.eql(u8, m, "stmia");
}

fn writeMemOp(
    w: *std.Io.Writer,
    image: ?elf.Image,
    addr: u32,
    dis_line: []const u8,
    parsed: *const ParsedDisasm,
    flow: *const dataflow_mod.InsnFlow,
) !void {
    const ops = parsed.ops();
    if (ops.len < 2) return w.print("/* {s} */", .{dis_line});
    const local_opt = if (image) |img| annotation_locals.nameAt(img, addr, dis_line) else null;
    if (isLoadMnemonic(parsed.mnemonic)) {
        if (flow.primary_val == .constant) {
            try w.print("{s} = ", .{ops[0]});
            return emit_format.writeConstant(w, image, flow.primary_val.constant, true);
        }
        if (local_opt) |loc| return w.print("{s} = {s}", .{ ops[0], loc });
        try w.print("{s} = {s}[", .{ ops[0], memWidthTag(parsed.mnemonic) });
        try writeMemExpr(w, ops);
        return w.writeByte(']');
    }
    if (local_opt) |loc| return w.print("{s} = {s}", .{ loc, ops[0] });
    try w.print("{s}[", .{memWidthTag(parsed.mnemonic)});
    try writeMemExpr(w, ops);
    try w.print("] = {s}", .{ops[0]});
}

fn memWidthTag(m: []const u8) []const u8 {
    if (std.mem.endsWith(u8, m, "sb")) return "smem8";
    if (std.mem.endsWith(u8, m, "sh")) return "smem16";
    if (std.mem.endsWith(u8, m, "b")) return "mem8";
    if (std.mem.endsWith(u8, m, "h")) return "mem16";
    if (std.mem.endsWith(u8, m, "d")) return "mem64";
    return "mem32";
}

fn writeMemExpr(w: *std.Io.Writer, ops: []const []const u8) !void {
    const bracket_slice = if (ops.len >= 2) stripBrackets(ops[1]) else "";
    var parts = std.mem.splitScalar(u8, bracket_slice, ',');
    const base = std.mem.trim(u8, parts.next() orelse "", " \t");
    if (parts.next()) |off| {
        const clean = cleanImm(std.mem.trim(u8, off, " \t"));
        if (clean.len > 0 and !std.mem.eql(u8, clean, "0")) {
            if (clean[0] == '-') {
                return w.print("{s} - {s}", .{ base, clean[1..] });
            }
            return w.print("{s} + {s}", .{ base, clean });
        }
    }
    try w.writeAll(base);
}

fn tryWriteCsel(
    w: *std.Io.Writer,
    image: ?elf.Image,
    m: []const u8,
    ops: []const []const u8,
    cond_opt: ?value.ConditionPair,
) !bool {
    const cp = cond_opt orelse return false;
    const is_csel = inList(&.{ "csel", "csinc", "csinv", "csneg" }, m);
    const is_alias = inList(&.{ "cset", "csetm", "cinc", "cinv", "cneg" }, m);
    if ((!is_csel and !is_alias) or ops.len < 2) return false;
    const eff_cond: u4 = if (is_alias) (cp.cond ^ 1) else cp.cond;
    try w.print("{s} = (", .{ops[0]});
    try emit_format.writeCondition(w, image, eff_cond, cp.origin, cp.self_reg);
    try w.writeAll(") ? ");
    try writeCselBranches(w, m, is_alias, ops);
    return true;
}

fn writeCselBranches(w: *std.Io.Writer, m: []const u8, is_alias: bool, ops: []const []const u8) !void {
    if (std.mem.eql(u8, m, "cset")) return w.writeAll("1 : 0");
    if (std.mem.eql(u8, m, "csetm")) return w.writeAll("-1 : 0");
    if (is_alias) {
        const rhs_mod = if (std.mem.eql(u8, m, "cinc"))
            "+ 1"
        else if (std.mem.eql(u8, m, "cinv"))
            "^ -1"
        else
            "* -1";
        return w.print("({s} {s}) : {s}", .{ ops[1], rhs_mod, ops[1] });
    }
    if (ops.len >= 3) return w.print("{s} : {s}", .{ ops[1], ops[2] });
}

fn writeAluOrMove(
    w: *std.Io.Writer,
    image: ?elf.Image,
    parsed: *const ParsedDisasm,
    flow: *const dataflow_mod.InsnFlow,
) !void {
    const m = parsed.mnemonic;
    const ops = parsed.ops();
    if (ops.len == 0) return w.print("/* {s} */", .{parsed.raw_mnemonic});
    if (isMoveMnemonic(m) and ops.len >= 2) return writeMove(w, image, m, ops, flow);
    if (binaryOpSymbol(m)) |sym| {
        if (ops.len == 3) {
            try w.print("{s} = {s} {s} {s}", .{ ops[0], ops[1], sym, cleanImm(ops[2]) });
        } else if (ops.len == 2) {
            try w.print("{s} {s}= {s}", .{ ops[0], sym, cleanImm(ops[1]) });
        } else {
            return w.print("/* {s} {s} */", .{ parsed.raw_mnemonic, parsed.args_str });
        }
        return maybeWriteFoldedComment(w, image, flow.primary_val);
    }
    if (try tryWriteBitOrExtend(w, m, ops)) return maybeWriteFoldedComment(w, image, flow.primary_val);
    if (flow.primary_rd) |rd| {
        if (flow.primary_val == .constant) {
            try w.print("{s} = ", .{text.names[rd]});
            return emit_format.writeConstant(w, image, flow.primary_val.constant, true);
        }
    }
    try w.print("/* {s} {s} */", .{ parsed.raw_mnemonic, parsed.args_str });
}

fn isMoveMnemonic(m: []const u8) bool {
    return inList(&.{ "mov", "movs", "movw", "movt", "mvn", "mvns", "adr" }, m);
}

fn writeMove(
    w: *std.Io.Writer,
    image: ?elf.Image,
    m: []const u8,
    ops: []const []const u8,
    flow: *const dataflow_mod.InsnFlow,
) !void {
    if (flow.primary_val == .constant) {
        try w.print("{s} = ", .{ops[0]});
        return emit_format.writeConstant(w, image, flow.primary_val.constant, true);
    }
    if (std.mem.eql(u8, m, "mvn") or std.mem.eql(u8, m, "mvns")) {
        return w.print("{s} = ~{s}", .{ ops[0], cleanImm(ops[1]) });
    }
    try w.print("{s} = {s}", .{ ops[0], cleanImm(ops[1]) });
}

const BinaryOpEntry = struct { mnem: []const u8, sym: []const u8 };
const binary_ops = [_]BinaryOpEntry{
    .{ .mnem = "add", .sym = "+" },  .{ .mnem = "adds", .sym = "+" },
    .{ .mnem = "sub", .sym = "-" },  .{ .mnem = "subs", .sym = "-" },
    .{ .mnem = "and", .sym = "&" },  .{ .mnem = "ands", .sym = "&" },
    .{ .mnem = "orr", .sym = "|" },  .{ .mnem = "orrs", .sym = "|" },
    .{ .mnem = "eor", .sym = "^" },  .{ .mnem = "eors", .sym = "^" },
    .{ .mnem = "lsl", .sym = "<<" }, .{ .mnem = "lsls", .sym = "<<" },
    .{ .mnem = "lsr", .sym = ">>" }, .{ .mnem = "lsrs", .sym = ">>" },
    .{ .mnem = "asr", .sym = ">>" }, .{ .mnem = "asrs", .sym = ">>" },
    .{ .mnem = "mul", .sym = "*" },  .{ .mnem = "muls", .sym = "*" },
    .{ .mnem = "udiv", .sym = "/" }, .{ .mnem = "sdiv", .sym = "/" },
};

fn binaryOpSymbol(m: []const u8) ?[]const u8 {
    for (binary_ops) |entry| {
        if (std.mem.eql(u8, m, entry.mnem)) return entry.sym;
    }
    return null;
}

const ExtendOpEntry = struct { mnem: []const u8, pre: []const u8, post: []const u8 };
const extend_ops = [_]ExtendOpEntry{
    .{ .mnem = "uxtb", .pre = "", .post = " & 0xff" },
    .{ .mnem = "uxth", .pre = "", .post = " & 0xffff" },
    .{ .mnem = "sxtb", .pre = "(i8)", .post = "" },
    .{ .mnem = "sxth", .pre = "(i16)", .post = "" },
};

fn tryWriteBitOrExtend(w: *std.Io.Writer, m: []const u8, ops: []const []const u8) !bool {
    if (ops.len < 2) return false;
    for (extend_ops) |entry| {
        if (std.mem.eql(u8, m, entry.mnem)) {
            try w.print("{s} = {s}{s}{s}", .{ ops[0], entry.pre, ops[1], entry.post });
            return true;
        }
    }
    if (ops.len < 4) return false;
    if (std.mem.eql(u8, m, "bfi")) {
        try w.print("{s} = bfi({s}, {s}, {s}, {s})", .{
            ops[0], ops[0], ops[1], cleanImm(ops[2]), cleanImm(ops[3]),
        });
        return true;
    }
    if (std.mem.eql(u8, m, "ubfx") or std.mem.eql(u8, m, "sbfx")) {
        try w.print("{s} = {s}({s}, {s}, {s})", .{
            ops[0], m, ops[1], cleanImm(ops[2]), cleanImm(ops[3]),
        });
        return true;
    }
    return false;
}

fn inList(list: []const []const u8, m: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, m, item)) return true;
    }
    return false;
}

fn maybeWriteFoldedComment(w: *std.Io.Writer, image: ?elf.Image, val: value.Value) !void {
    const c = val.asConstant() orelse return;
    try w.writeAll(" /* = ");
    try emit_format.writeConstant(w, image, c, false);
    try w.writeAll(" */");
}

fn cleanImm(tok: []const u8) []const u8 {
    if (tok.len > 0 and tok[0] == '#') return tok[1..];
    return tok;
}

fn stripBrackets(tok: []const u8) []const u8 {
    var s = std.mem.trim(u8, tok, " \t!");
    if (s.len > 0 and s[0] == '[') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == ']') s = s[0 .. s.len - 1];
    return s;
}
