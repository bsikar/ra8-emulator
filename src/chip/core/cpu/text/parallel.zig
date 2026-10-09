//! Text for the parallel group: {s,q,sh,u,uq,uh}{add8,add16,asx,sub8,sub16,sax}
//! Rd, Rn, Rm, in the spelling the parity digests pin.
const std = @import("std");
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const parallel = @import("../ops/parallel.zig");

/// Prefix by [unsigned][mode].
const prefixes = [2][3][]const u8{
    .{ "s", "q", "sh" },
    .{ "u", "uq", "uh" },
};

/// Every mnemonic, built once: [unsigned][mode][shape].
const mnemonics = blk: {
    const shapes = std.meta.fieldNames(parallel.Shape);
    var out: [2][3][shapes.len][]const u8 = undefined;
    for (0..2) |u| {
        for (0..3) |m| {
            for (shapes, 0..) |shape, s| out[u][m][s] = prefixes[u][m] ++ shape;
        }
    }
    break :blk out;
};

pub fn print(instr: Instr, out: *text.Text) void {
    const f = parallel.Fields.of(instr) orelse return;
    const u = @intFromBool(!f.signed);
    const name = mnemonics[u][@backingInt(f.mode)][@backingInt(f.shape)];
    out.regs3(name, f.rd, f.rn, f.rm);
}
