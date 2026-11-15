//! DWARF variable location classification and frame-base evaluation.
const Cursor = @import("cursor.zig").Cursor;
const frame = @import("frame.zig");
const std = @import("std");
const unwind = @import("../unwind/unwind.zig");

const dwarf = std.dwarf;

pub const ReadOnlyReason = enum {
    optimized_out,
    const_value,
    location_list,
    composite,
    implicit_value,
    multi_op,
    unsupported_op,
    missing_frame_base,
};

pub const Location = union(enum) {
    frame: i64,
    register_offset: struct { reg: u8, offset: i64 },
    in_register: u8,
    address: u32,
    read_only: ReadOnlyReason,
};

/// Human-readable reason why a variable cannot be written safely.
pub fn reasonText(reason: ReadOnlyReason) []const u8 {
    return switch (reason) {
        .optimized_out => "variable is optimized out (no DWARF location)",
        .const_value => "variable is a compile-time constant (DW_AT_const_value)",
        .location_list => "variable uses a DWARF location list (read-only here)",
        .composite => "variable has a composite DWARF location (DW_OP_piece)",
        .implicit_value => "variable has an implicit DWARF value (no mutable storage)",
        .multi_op => "variable uses a multi-op DWARF location expression (read-only)",
        .unsupported_op => "variable uses an unsupported DWARF location opcode",
        .missing_frame_base => "frame base unavailable to resolve local stack offset",
    };
}

/// Compute the byte address of `frame_base_expr` at the registers in `regs`.
pub fn frameBaseAddress(frame_bytes: []const u8, expr: []const u8, regs: unwind.Registers) error{MissingFrameBase}!u32 {
    if (expr.len == 0) return error.MissingFrameBase;
    var cur = Cursor{ .bytes = expr };
    const op = cur.byte() catch return error.MissingFrameBase;
    if (op == dwarf.OP.call_frame_cfa and cur.done()) {
        const pc = regs[15] & ~@as(u32, 1);
        const found = frame.find(frame_bytes, pc) catch return error.MissingFrameBase;
        const fde = found orelse return error.MissingFrameBase;
        const row = frame.rowAt(fde, pc) catch return error.MissingFrameBase;
        if (row.cfa.register >= regs.len) return error.MissingFrameBase;
        return addSigned(regs[row.cfa.register], row.cfa.offset);
    }
    if (op >= dwarf.OP.reg0 and op <= dwarf.OP.reg0 + 15 and cur.done()) {
        return regs[op - dwarf.OP.reg0];
    }
    if (op >= dwarf.OP.breg0 and op <= dwarf.OP.breg0 + 15) {
        const off = cur.sleb() catch return error.MissingFrameBase;
        if (cur.done()) return addSigned(regs[op - dwarf.OP.breg0], off);
    }
    if (op == dwarf.OP.addr and expr.len == 5) {
        const addr = cur.int(u32) catch return error.MissingFrameBase;
        if (cur.done()) return addr;
    }
    return error.MissingFrameBase;
}

/// Classify a variable's DWARF `DW_AT_location` into a mutable storage target or read-only reason.
pub fn classify(loc_form: ?u64, loc_bytes: ?[]const u8, has_const_val: bool, addr_size: u8) Location {
    const form = loc_form orelse return .{ .read_only = if (has_const_val) .const_value else .optimized_out };
    if (form == dwarf.FORM.sec_offset or form == dwarf.FORM.loclistx) return .{ .read_only = .location_list };
    const expr = loc_bytes orelse return .{ .read_only = .optimized_out };
    if (expr.len == 0) return .{ .read_only = .optimized_out };
    if (parseSingleOp(expr, addr_size)) |loc| return loc;
    return .{ .read_only = classifyComplexExpr(expr, addr_size) };
}

fn parseSingleOp(expr: []const u8, addr_size: u8) ?Location {
    var cur = Cursor{ .bytes = expr };
    const op = cur.byte() catch return null;
    if (op == dwarf.OP.fbreg) {
        const off = cur.sleb() catch return null;
        if (cur.done()) return .{ .frame = off };
    } else if (op >= dwarf.OP.reg0 and op <= dwarf.OP.reg31) {
        if (cur.done()) return .{ .in_register = op - dwarf.OP.reg0 };
    } else if (op == dwarf.OP.regx) {
        const reg = cur.uleb() catch return null;
        if (cur.done() and reg <= 31) return .{ .in_register = @intCast(reg) };
    } else if (op >= dwarf.OP.breg0 and op <= dwarf.OP.breg31) {
        const off = cur.sleb() catch return null;
        if (cur.done()) return .{ .register_offset = .{ .reg = op - dwarf.OP.breg0, .offset = off } };
    } else if (op == dwarf.OP.bregx) {
        const reg = cur.uleb() catch return null;
        const off = cur.sleb() catch return null;
        if (cur.done() and reg <= 31) return .{ .register_offset = .{ .reg = @intCast(reg), .offset = off } };
    } else if (op == dwarf.OP.addr and addr_size == 4) {
        const addr = cur.int(u32) catch return null;
        if (cur.done()) return .{ .address = addr };
    }
    return null;
}

fn classifyComplexExpr(expr: []const u8, addr_size: u8) ReadOnlyReason {
    var cur = Cursor{ .bytes = expr };
    var ops: usize = 0;
    while (!cur.done()) {
        const op = cur.byte() catch return .unsupported_op;
        ops += 1;
        if (op == dwarf.OP.piece or op == dwarf.OP.bit_piece) return .composite;
        if (op == dwarf.OP.stack_value or
            op == dwarf.OP.implicit_value or
            op == dwarf.OP.implicit_pointer or
            op == dwarf.OP.GNU_implicit_pointer)
        {
            return .implicit_value;
        }
        skipOperands(&cur, op, addr_size) catch return .unsupported_op;
    }
    return if (ops > 1) .multi_op else .unsupported_op;
}

fn skipOperands(cur: *Cursor, op: u8, addr_size: u8) !void {
    switch (op) {
        dwarf.OP.addr => try cur.skip(addr_size),
        dwarf.OP.const1u,
        dwarf.OP.const1s,
        dwarf.OP.pick,
        dwarf.OP.deref_size,
        dwarf.OP.xderef_size,
        => _ = try cur.byte(),
        dwarf.OP.const2u, dwarf.OP.const2s, dwarf.OP.skip, dwarf.OP.bra => _ = try cur.int(u16),
        dwarf.OP.const4u, dwarf.OP.const4s => _ = try cur.int(u32),
        dwarf.OP.const8u, dwarf.OP.const8s => _ = try cur.int(u64),
        dwarf.OP.constu,
        dwarf.OP.plus_uconst,
        dwarf.OP.regx,
        dwarf.OP.piece,
        dwarf.OP.addrx,
        dwarf.OP.constx,
        => _ = try cur.uleb(),
        dwarf.OP.consts, dwarf.OP.fbreg, dwarf.OP.breg0...dwarf.OP.breg31 => _ = try cur.sleb(),
        dwarf.OP.bregx, dwarf.OP.bit_piece => {
            _ = try cur.uleb();
            _ = try cur.sleb();
        },
        else => {},
    }
}

fn addSigned(base: u32, delta: i64) u32 {
    const wrapped: i64 = @as(i64, base) + delta;
    return @truncate(@as(u64, @bitCast(wrapped)));
}
