//! Text for the hint group. 16-bit: NOP, YIELD, WFE, WFI and SEV by name, and
//! any other hint as `hint #n`. 32-bit, in Capstone 5's spelling: the named
//! hints 0-4 and ESB with a `.w` suffix, `csdb`, `dbg #n` for 0xF0-0xFF, and
//! `hint.w #n` for the rest.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

const named = [5][]const u8{ "nop", "yield", "wfe", "wfi", "sev" };
const named_wide = [5][]const u8{ "nop.w", "yield.w", "wfe.w", "wfi.w", "sev.w" };
const esb: u16 = 0x10;
const csdb: u16 = 0x14;
const dbg_first: u16 = 0xF0;

pub fn print(instr: Instr, out: *text.Text) void {
    if (instr.size == 4) return printWide(instr.hw2 & 0xFF, out);
    const hint = (instr.hw1 >> 4) & 0xF;
    if (hint < named.len) return out.put("{s}", .{named[hint]});
    out.put("hint ", .{});
    out.imm(hint);
}

fn printWide(hint: u16, out: *text.Text) void {
    if (hint < named_wide.len) return out.put("{s}", .{named_wide[hint]});
    if (hint == esb) return out.put("esb.w", .{});
    if (hint == csdb) return out.put("csdb", .{});
    if (hint >= dbg_first) {
        out.put("dbg ", .{});
        return out.imm(hint & 0xF);
    }
    out.put("hint.w ", .{});
    out.imm(hint);
}
