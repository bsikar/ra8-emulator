//! Text for the vscclrm group (Armv8.1-M), in Arm ARM syntax: the run of
//! registers cleared, then VPR, which is always cleared: `vscclrm {s0-s3,
//! vpr}`, `vscclrm {d8-d15, vpr}`, `vscclrm {s5, vpr}`, or `vscclrm {vpr}`
//! for an empty run. The run comes from the executor's own `run`, so text and
//! execution cannot disagree. We read the encoding as a VLDMIA.
const Instr = @import("../instr.zig").Instr;
const ops = @import("../ops/vscclrm.zig");
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const run = ops.run(instr) orelse return;
    out.put("vscclrm {{", .{});
    if (run.count != 0) {
        if (instr.hw2 & ops.encodings.double != 0) {
            range(out, 'd', run.first / 2, run.count / 2);
        } else {
            range(out, 's', run.first, run.count);
        }
        out.put(", ", .{});
    }
    out.put("vpr}}", .{});
}

fn range(out: *text.Text, kind: u8, first: u6, count: u6) void {
    if (count == 1) return out.put("{c}{d}", .{ kind, first });
    out.put("{c}{d}-{c}{d}", .{ kind, first, kind, first + count - 1 });
}
