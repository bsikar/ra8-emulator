//! Text for the barrier group: dsb, dmb and isb with their option.
//!
//! DSB and DMB name the options Capstone 5 names (the store and full
//! options, not the load-only ones) and print the rest as an immediate.
//! Capstone prints DSB option 0b1100 as the Armv8-R `dfb` alias, so this
//! does too: the text has to match it for the parity checks. ISB names
//! only `sy` and prints every other option in hex.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const barrier = @import("../ops/barrier.zig");

/// Option names for DSB and DMB, indexed by the option; null prints `#n`.
/// Capstone 5 leaves the load-only options (oshld, nshld, ishld, ld) as
/// immediates, so they are null here too.
const option_names = [16]?[]const u8{
    null, null, "oshst", "osh",
    null, null, "nshst", "nsh",
    null, null, "ishst", "ish",
    null, null, "st",    "sy",
};
const sy: u4 = 0xF;
const dfb_option: u4 = 0xC;

pub fn print(instr: Instr, out: *text.Text) void {
    const option: u4 = @intCast(instr.hw2 & 0xF);
    switch (instr.hw2 & barrier.encodings.option_mask) {
        barrier.encodings.isb => {
            if (option == sy) out.put("isb sy", .{}) else out.put("isb #0x{x}", .{option});
        },
        else => |kind| {
            const dsb = kind == barrier.encodings.dsb;
            if (dsb and option == dfb_option) return out.put("dfb", .{});
            out.put("{s} ", .{if (dsb) "dsb" else "dmb"});
            if (option_names[option]) |name| out.put("{s}", .{name}) else out.imm(option);
        },
    }
}
