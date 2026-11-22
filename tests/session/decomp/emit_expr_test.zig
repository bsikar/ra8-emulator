//! Covers src/session/decomp/emit_expr.zig.
const std = @import("std");
const ra8 = @import("ra8");

const decomp = ra8.session.decomp;

fn formatLine(dis_line: []const u8, flow: decomp.dataflow.InsnFlow, cp: ?decomp.value.ConditionPair) ![]const u8 {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try decomp.emit_expr.writeInstruction(&w, null, flow.address, dis_line, &flow, null, cp);
    return std.testing.allocator.dupe(u8, w.buffered());
}

test "writeInstruction formats prologue, memory, cset, bitfield, and folded constant statements" {
    const push_out = try formatLine("push {r4, lr}", .{
        .insn_idx = 0,
        .block_id = 0,
        .address = 0x100,
        .uses_mask = 0,
        .defs_mask = 0,
        .primary_rd = 13,
        .primary_val = .{ .sp_offset = -8 },
        .cond_active = null,
        .reg_defs = &.{},
    }, null);
    defer std.testing.allocator.free(push_out);
    try std.testing.expectEqualStrings("save({r4, lr})", push_out);

    const bfi_out = try formatLine("bfi r3, r1, #8, #8", .{
        .insn_idx = 1,
        .block_id = 0,
        .address = 0x102,
        .uses_mask = 0,
        .defs_mask = 0,
        .primary_rd = 3,
        .primary_val = .{ .constant = 0x0302 },
        .cond_active = null,
        .reg_defs = &.{},
    }, null);
    defer std.testing.allocator.free(bfi_out);
    try std.testing.expectEqualStrings("r3 = bfi(r3, r1, 8, 8) /* = 0x302 */", bfi_out);

    const cset_out = try formatLine("cset r0, eq", .{
        .insn_idx = 2,
        .block_id = 0,
        .address = 0x106,
        .uses_mask = 0,
        .defs_mask = 1,
        .primary_rd = 0,
        .primary_val = .unknown,
        .cond_active = null,
        .reg_defs = &.{},
    }, .{
        .consumer_insn = 2,
        .consumer_addr = 0x106,
        .cond = 1, // inverted eq -> stored raw cond is ne (1), cset flips back to eq (0)
        .origin = .{ .setter_insn = 0, .setter_addr = 0x100, .kind = .cmp, .lhs_reg = 2, .rhs_imm = 0 },
    });
    defer std.testing.allocator.free(cset_out);
    try std.testing.expectEqualStrings("r0 = (r2 == 0) ? 1 : 0", cset_out);

    const mem_out = try formatLine("ldr r3, [r7, #0x14]", .{
        .insn_idx = 3,
        .block_id = 0,
        .address = 0x10a,
        .uses_mask = 0,
        .defs_mask = 8,
        .primary_rd = 3,
        .primary_val = .unknown,
        .cond_active = null,
        .reg_defs = &.{},
    }, null);
    defer std.testing.allocator.free(mem_out);
    try std.testing.expectEqualStrings("r3 = mem32[r7 + 0x14]", mem_out);
}
