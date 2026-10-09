//! UAL text for lazy floating-point context transfers, per DDI0553 C2.4.367-368.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const load = instr.hw1 & 0x10 != 0;
    const t2 = instr.hw2 & 0x80 != 0;
    out.put("{s} {s}", .{ if (load) "vlldm" else "vlstm", text.names[instr.hw1 & 0xF] });
    if (t2) out.put(", {{d0-d31}}", .{}) else out.put(", {{d0-d15}}", .{});
}
