//! Scope-checked DWARF names for simple storage operands, without reading memory.
const std = @import("std");

const Cursor = @import("dwarf/cursor.zig").Cursor;
const dwarf = @import("dwarf/dwarf.zig");
const elf = @import("ra8_board").image.elf;
const operands = @import("annotation_operands.zig");
const text = @import("ra8_chip").core.cpu.text.text;

pub fn append(image: elf.Image, pc: u32, into: *text.Text) void {
    const name = nameAt(image, pc, into.slice()) orelse return;
    // One unambiguous name keeps a crowded alias set from overflowing text.
    into.put(" ; local {s}", .{name});
}

/// Return the active-scope DWARF local variable name matching `line` at `pc`, if any.
pub fn nameAt(image: elf.Image, pc: u32, line: []const u8) ?[]const u8 {
    const sections = dwarf.locals.ofImage(image);
    var rows: [64]dwarf.locals.Local = undefined;
    const count = dwarf.locals.inFunction(sections, pc, &rows) catch return null;
    for (rows[0..count]) |row| {
        if (row.name.len == 0) continue;
        const local = (dwarf.vars.findLocal(sections, pc, row.name) catch null) orelse continue;
        if (!touches(image, pc, local, line)) continue;
        return local.name;
    }
    return null;
}

fn touches(image: elf.Image, pc: u32, local: dwarf.vars.Variable, line: []const u8) bool {
    return switch (local.location) {
        .in_register => |reg| operands.usesRegister(line, reg),
        .register_offset => |where| matches(line, .{ .reg = where.reg, .offset = where.offset }),
        .frame => |offset| blk: {
            var base = frameBase(image, pc, local.frame_base_expr) orelse break :blk false;
            base.offset = std.math.add(i64, base.offset, offset) catch break :blk false;
            break :blk matches(line, base);
        },
        else => false,
    };
}

fn matches(line: []const u8, wanted: operands.Memory) bool {
    const found = operands.memory(line) orelse return false;
    return found.reg == wanted.reg and found.offset == wanted.offset;
}

fn frameBase(image: elf.Image, pc: u32, expr: []const u8) ?operands.Memory {
    var cursor: Cursor = .{ .bytes = expr };
    const op = cursor.byte() catch return null;
    if (op == std.dwarf.OP.call_frame_cfa and cursor.done()) {
        const fde = (dwarf.frame.find(dwarf.vars.frameSection(image), pc) catch null) orelse return null;
        const row = dwarf.frame.rowAt(fde, pc) catch return null;
        return .{ .reg = row.cfa.register, .offset = row.cfa.offset };
    }
    if (op >= std.dwarf.OP.reg0 and op <= std.dwarf.OP.reg0 + 15 and cursor.done()) {
        return .{ .reg = op - std.dwarf.OP.reg0 };
    }
    if (op >= std.dwarf.OP.breg0 and op <= std.dwarf.OP.breg0 + 15) {
        const offset = cursor.sleb() catch return null;
        if (cursor.done()) return .{ .reg = op - std.dwarf.OP.breg0, .offset = offset };
    }
    return null;
}
