//! Text for the lob group (Armv8.1-M), in Arm ARM syntax: `dls lr, rn`,
//! `wls lr, rn, #target` and `le lr, #target`. The target is absolute, like
//! the other branches: forward from the next instruction for WLS, backward
//! for LE, the same way src/core/lob.zig's `step` moves the PC.
const Instr = @import("../instr.zig").Instr;
const ops = @import("../ops/lob.zig");
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = ops.fields(instr) orelse return;
    const distance: i32 = @intCast(f.offset);
    switch (f.kind) {
        .dls => out.put("dls lr, {s}", .{text.names[f.source]}),
        .wls => {
            out.put("wls lr, {s}, ", .{text.names[f.source]});
            out.target(instr.address, distance);
        },
        .le => {
            out.put("le lr, ", .{});
            out.target(instr.address, -distance);
        },
    }
}
