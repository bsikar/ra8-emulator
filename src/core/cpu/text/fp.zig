//! Armv8-M floating-point instruction text printers.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

fn freg(out: *text.Text, r: u5, d: bool) void {
    out.put("{s}{d}", .{ if (d) "d" else "s", r });
}
fn reg(lo: u5, ext: u5, d: bool) u5 {
    return if (d) ext << 4 | lo else lo << 1 | ext;
}
fn fpRd(i: Instr, d: bool) u5 {
    return reg(@intCast(i.hw2 >> 12 & 0xF), @intCast(i.hw1 >> 6 & 1), d);
}
fn fpRn(i: Instr, d: bool) u5 {
    return reg(@intCast(i.hw1 & 0xF), @intCast(i.hw2 >> 7 & 1), d);
}
fn fpRm(i: Instr, d: bool) u5 {
    return reg(@intCast(i.hw2 & 0xF), @intCast(i.hw2 >> 5 & 1), d);
}
fn wide(i: Instr) bool {
    return i.hw2 & 0x0F10 != 0x0900 and i.hw2 >> 8 & 1 == 1;
}
fn fmt(d: bool) []const u8 {
    return if (d) ".f64" else ".f32";
}
fn fmtOf(i: Instr, d: bool) []const u8 {
    return if (i.hw2 & 0x0F10 == 0x0900) ".f16" else fmt(d);
}

pub fn arith(i: Instr, o: *text.Text) void {
    const k: u3 = @intCast((i.hw1 >> 5 & 4) | (i.hw1 >> 4 & 3));
    const neg = i.hw2 >> 6 & 1 == 1;
    const m: []const u8 = switch (k) {
        0 => if (neg) "vmls" else "vmla",
        1 => if (neg) "vnmla" else "vnmls",
        2 => if (neg) "vnmul" else "vmul",
        3 => if (neg) "vsub" else "vadd",
        4 => "vdiv",
        5 => if (neg) "vfnma" else "vfnms",
        6 => if (neg) "vfms" else "vfma",
        else => unreachable,
    };
    const d = wide(i);
    const rd = fpRd(i, d);
    o.put("{s}{s} ", .{ m, fmtOf(i, d) });
    freg(o, rd, d);
    o.put(", ", .{});
    if (k < 2 or k >= 5) {
        freg(o, rd, d);
        o.put(", ", .{});
    }
    freg(o, fpRn(i, d), d);
    o.put(", ", .{});
    freg(o, fpRm(i, d), d);
}
fn halfValue(bits: u16) f32 {
    const sign: u32 = @as(u32, bits >> 15) << 31;
    var exp: i32 = @intCast(bits >> 10 & 0x1F);
    var frac: u32 = bits & 0x03FF;
    if (exp == 0 and frac != 0) {
        exp = -14;
        while (frac & 0x400 == 0) {
            frac <<= 1;
            exp -= 1;
        }
        frac &= 0x3FF;
        exp += 127;
    } else if (exp == 0) {
        exp = 0;
    } else if (exp == 31) {
        exp = 255;
    } else {
        exp += 112;
    }
    const raw = sign | @as(u32, @intCast(exp)) << 23 | frac << 13;
    return @bitCast(raw);
}
pub fn unary(i: Instr, o: *text.Text) void {
    const op: u4 = @truncate(i.hw1);
    const immediate = i.hw2 & 0x00F0 == 0;
    const d = wide(i);
    if (immediate) {
        o.put("vmov{s} ", .{fmtOf(i, d)});
        freg(o, fpRd(i, d), d);
        const imm8: u8 = @intCast((i.hw1 & 0xF) << 4 | (i.hw2 & 0xF));
        const sign: u64 = imm8 >> 7;
        const b: u64 = imm8 >> 6 & 1;
        const half = i.hw2 & 0x0F10 == 0x0900;
        const ebits: u6 = if (d) 11 else if (half) 5 else 8;
        const fbits: u6 = if (d) 52 else if (half) 10 else 23;
        const repeated: u64 = if (b == 1) (@as(u64, 1) << (ebits - 3)) - 1 else 0;
        const exp = (b ^ 1) << (ebits - 1) | repeated << 2 | (imm8 >> 4 & 3);
        const frac = @as(u64, imm8 & 0xF) << (fbits - 4);
        if (d) {
            const bits = sign << 63 | exp << 52 | frac;
            const value: f64 = @bitCast(bits);
            if (@trunc(value) == value) o.put(", #{d}.0", .{value}) else o.put(", #{d}", .{value});
        } else if (half) {
            const raw: u16 = @intCast(sign << 15 | exp << 10 | frac);
            const value = halfValue(raw);
            if (@trunc(value) == value) o.put(", #{d}.0", .{value}) else o.put(", #{d}", .{value});
        } else {
            const bits = sign << 31 | exp << 23 | frac;
            const value: f32 = @bitCast(@as(u32, @truncate(bits)));
            if (@trunc(value) == value) o.put(", #{d}.0", .{value}) else o.put(", #{d}", .{value});
        }
        return;
    }
    const m: []const u8 = switch (op) {
        0 => if (i.hw2 & 0xC0 == 0xC0) "vabs" else "vmov",
        1 => if (i.hw2 & 0xC0 == 0xC0) "vsqrt" else "vneg",
        else => "vmov",
    };
    o.put("{s}{s} ", .{ m, fmtOf(i, d) });
    freg(o, fpRd(i, d), d);
    o.put(", ", .{});
    freg(o, fpRm(i, d), d);
}
pub fn system(i: Instr, o: *text.Text) void {
    if (i.hw2 & 0x0FFF == 0x0A10) {
        const id: u4 = @truncate(i.hw1);
        const rt = i.hw2 >> 12;
        const load = i.hw1 >> 4 & 1 == 1;
        const names = [_][]const u8{ "", "fpscr", "fpscr_nzcvqc", "", "", "", "", "", "", "", "", "", "vpr", "p0", "fpcxt_ns", "fpcxt_s" };
        if (load and rt == 15 and id == 1) {
            o.put("vmrs apsr_nzcv, fpscr", .{});
        } else if (load) {
            o.put("vmrs {s}, {s}", .{ text.names[rt], names[id] });
        } else {
            o.put("vmsr {s}, {s}", .{ names[id], text.names[rt] });
        }
        return;
    }
    const d = wide(i);
    const zero = i.hw1 & 1 == 1;
    o.put("vcmp{s}{s} ", .{ if (i.hw2 >> 7 & 1 == 1) "e" else "", fmtOf(i, d) });
    freg(o, fpRd(i, d), d);
    o.put(", ", .{});
    if (zero) o.put("#0.0", .{}) else freg(o, fpRm(i, d), d);
}
pub fn convert(i: Instr, o: *text.Text) void {
    const k: u4 = @truncate(i.hw1);
    const sz = i.hw2 >> 8 & 1 == 1;
    const dest = fpRd(i, sz);
    const src = fpRm(i, sz);
    if (k == 7) {
        o.put("vcvt{s}{s} ", .{ fmt(!sz), fmt(sz) });
        freg(o, fpRd(i, !sz), !sz);
        o.put(", ", .{});
        freg(o, fpRm(i, sz), sz);
    } else if (k == 12 or k == 13) {
        o.put("{s}.{s}{s} ", .{ if (i.hw2 >> 7 & 1 == 1) "vcvt" else "vcvtr", if (k == 12) "u32" else "s32", fmt(sz) });
        freg(o, fpRd(i, false), false);
        o.put(", ", .{});
        freg(o, src, sz);
    } else if (k == 8) {
        o.put("vcvt{s}.{s} ", .{ fmt(sz), if (i.hw2 >> 7 & 1 == 1) "s32" else "u32" });
        freg(o, dest, sz);
        o.put(", ", .{});
        freg(o, fpRm(i, false), false);
    } else if (k == 10 or k == 11 or k == 14 or k == 15) {
        const width: u6 = if (i.hw2 >> 7 & 1 == 1) 32 else 16;
        const imm5: u6 = @intCast((i.hw2 & 0xF) << 1 | (i.hw2 >> 5 & 1));
        const fbits = width - imm5;
        if (k == 14 or k == 15) {
            o.put("vcvt.{s}{s}{s} ", .{ if (i.hw1 & 1 == 1) "u" else "s", if (width == 16) "16" else "32", fmt(sz) });
            freg(o, dest, sz);
            o.put(", ", .{});
            freg(o, dest, sz);
        } else {
            o.put("vcvt{s}.{s}{s} ", .{ fmt(sz), if (i.hw1 & 1 == 1) "u" else "s", if (width == 16) "16" else "32" });
            freg(o, dest, sz);
            o.put(", ", .{});
            freg(o, dest, sz);
        }
        o.put(", #{d}", .{fbits});
    } else if (k == 2) {
        o.put("{s}{s}.f16 ", .{ if (i.hw2 >> 7 & 1 == 1) "vcvtt" else "vcvtb", fmt(sz) });
        freg(o, fpRd(i, sz), sz);
        o.put(", ", .{});
        freg(o, fpRm(i, false), false);
    } else if (k == 3) {
        o.put("{s}.f16.f{d} ", .{ if (i.hw2 >> 7 & 1 == 1) "vcvtt" else "vcvtb", if (sz) @as(u8, 64) else 32 });
        freg(o, fpRd(i, false), false);
        o.put(", ", .{});
        freg(o, fpRm(i, sz), sz);
    }
}
pub fn directed(i: Instr, o: *text.Text) void {
    const h = i.hw1;
    const d = wide(i);
    const is_sel = h & 0xFF80 == 0xFE00;
    const maxmin = h & 0xFFB0 == 0xFE80;
    if (is_sel) {
        const cc = [_][]const u8{ "eq", "vs", "ge", "gt" };
        o.put("vsel{s}{s} ", .{ cc[(h >> 4) & 3], fmtOf(i, d) });
    } else if (maxmin) {
        o.put("{s}{s} ", .{ if (i.hw2 >> 6 & 1 == 1) "vminnm" else "vmaxnm", fmtOf(i, d) });
    } else if (h & 0xFFBC == 0xFEBC) {
        const round = [_][]const u8{ "a", "n", "p", "m" };
        o.put("vcvt{s}.{s}{s} ", .{ round[h & 3], if (i.hw2 >> 7 & 1 == 1) "s32" else "u32", fmtOf(i, d) });
    } else if (h & 0xFFBF == 0xEEB6) {
        o.put("{s}{s} ", .{ if (i.hw2 >> 7 & 1 == 1) "vrintr" else "vrintz", fmtOf(i, d) });
    } else if (h & 0xFFBF == 0xEEB7) {
        o.put("vrintx{s} ", .{fmtOf(i, d)});
    } else {
        const round = [_][]const u8{ "a", "n", "p", "m" };
        o.put("vrint{s}{s} ", .{ round[h & 3], fmtOf(i, d) });
    }
    freg(o, fpRd(i, if (h & 0xFFBC == 0xFEBC) false else d), if (h & 0xFFBC == 0xFEBC) false else d);
    o.put(", ", .{});
    if (is_sel or maxmin) {
        freg(o, fpRn(i, d), d);
        o.put(", ", .{});
    }
    freg(o, fpRm(i, d), d);
}
pub fn move(i: Instr, o: *text.Text) void {
    const core = i.hw1 & 0xFFE0 == 0xEE00;
    const to = i.hw1 >> 4 & 1 == 1;
    if (core) {
        const r = text.names[i.hw2 >> 12];
        const f: u5 = @intCast((i.hw1 & 0xF) << 1 | (i.hw2 >> 7 & 1));
        if (to) {
            o.put("vmov {s}, ", .{r});
            freg(o, f, false);
        } else {
            o.put("vmov ", .{});
            freg(o, f, false);
            o.put(", {s}", .{r});
        }
        return;
    }
    const d = wide(i);
    const r = text.names[i.hw2 >> 12];
    const r2 = text.names[i.hw1 & 0xF];
    const f = fpRm(i, d);
    if (to) {
        o.put("vmov {s}, {s}, ", .{ r, r2 });
        freg(o, f, d);
        if (!d) {
            o.put(", ", .{});
            freg(o, f + 1, false);
        }
    } else {
        o.put("vmov ", .{});
        freg(o, f, d);
        if (!d) {
            o.put(", ", .{});
            freg(o, f + 1, false);
        }
        o.put(", {s}, {s}", .{ r, r2 });
    }
}
pub fn mem(i: Instr, o: *text.Text) void {
    const p = i.hw1 >> 8 & 1 == 1;
    const u = i.hw1 >> 7 & 1 == 1;
    const w = i.hw1 >> 5 & 1 == 1;
    const load = i.hw1 >> 4 & 1 == 1;
    const rn_index: u4 = @truncate(i.hw1);
    const rn = text.names[rn_index];
    const half = i.hw2 & 0x0F00 == 0x0900;
    const d = !half and i.hw2 >> 8 & 1 == 1;
    const rd = fpRd(i, d);
    if (i.hw2 & 0x0F80 == 0x0F80) {
        const id: u4 = @intCast((i.hw1 >> 3 & 8) | (i.hw2 >> 12));
        const names = [_][]const u8{ "", "fpscr", "fpscr_nzcvqc", "", "", "", "", "", "", "", "", "", "vpr", "p0", "fpccr_ns", "fpcxt_s" };
        o.put("{s} ", .{if (load) "vldr" else "vstr"});
        o.put("{s}, [{s}", .{ names[id], rn });
    } else if (p and !w) {
        o.put("{s}{s} ", .{ if (load) "vldr" else "vstr", if (half) ".16" else fmt(d) });
        freg(o, rd, d);
        o.put(", [{s}", .{rn});
    } else {
        const push = rn_index == 13 and w and !load and p and !u;
        const pop = rn_index == 13 and w and load and !p and u;
        if (push or pop) {
            o.put("{s} ", .{if (push) "vpush" else "vpop"});
        } else {
            const mode = if (!p and u) "ia" else if (!p and !u) "da" else if (p and u) "ib" else "db";
            o.put("{s}{s} {s}{s}, ", .{ if (load) "vldm" else "vstm", mode, rn, if (w) "!" else "" });
        }
        const count: u5 = if (d) @intCast((i.hw2 & 0xFF) / 2) else @intCast(i.hw2 & 0xFF);
        o.put("{{", .{});
        freg(o, rd, d);
        o.put("-", .{});
        freg(o, rd + count - 1, d);
        o.put("}}", .{});
        return;
    }
    const offset: u32 = @as(u32, i.hw2 & 0xFF) * @as(u32, if (half) 2 else 4);
    if (offset != 0) {
        o.put(", ", .{});
        if (u) o.imm(offset) else o.signedImm(0 -% offset);
    }
    o.put("]", .{});
}
