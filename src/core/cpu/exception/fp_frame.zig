//! The extended exception frame (RA8EMU-124): the basic eight words, then
//! S0-S15, FPSCR and VPR, 0x68 bytes in all. Entry pushes it
//! when an FP context is active and clears EXC_RETURN.FType; a return with
//! FType clear pops it. The Secure S16-S31 extension is RA8EMU-165 and lazy
//! preservation is RA8EMU-163. The word after FPSCR is VPR on a core with
//! MVE (RA8EMU-330) and reserved, stacked as 0, on one without.
const std = @import("std");
const bus = @import("../bus.zig");
const frame = @import("frame.zig");

pub const size: u32 = 0x68;
pub const words = 26;

/// Word offsets past the basic frame.
pub const slot = struct {
    pub const s0: usize = frame.words;
    pub const fpscr: usize = frame.words + 16;
    pub const vpr: usize = frame.words + 17;
};

/// The FP half of the frame.
pub const Fp = struct {
    s: [16]u32,
    fpscr: u32,
    vpr: u32 = 0,
};

/// Push the basic `basic` frame and `fp` below `sp`; give back the new
/// stack pointer. Bit 9 of the stacked xPSR records any realignment.
pub fn push(to: bus.Bus, sp: u32, basic: frame.Frame, fp: Fp) bus.Error!u32 {
    const pad = sp & 4;
    const at = (sp -% size) & ~pad;
    var all: [words]u32 = [_]u32{0} ** words;
    @memcpy(all[0..frame.words], &basic);
    all[frame.slot.xpsr] &= ~frame.realigned;
    if (pad != 0) all[frame.slot.xpsr] |= frame.realigned;
    @memcpy(all[slot.s0..slot.fpscr], &fp.s);
    all[slot.fpscr] = fp.fpscr;
    all[slot.vpr] = fp.vpr;
    for (all, 0..) |word, i| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, word, .little);
        try to.write(at +% @as(u32, @intCast(i * 4)), &bytes);
    }
    return at;
}

pub const Popped = struct {
    frame: frame.Frame,
    fp: Fp,
    /// The stack pointer once the frame, and any realignment word, is gone.
    sp: u32,
};

pub fn pop(from: bus.Bus, at: u32) bus.Error!Popped {
    var all: [words]u32 = undefined;
    for (&all, 0..) |*word, i| word.* = try from.readWord(at +% @as(u32, @intCast(i * 4)));
    var popped: Popped = .{ .frame = undefined, .fp = .{ .s = undefined, .fpscr = all[slot.fpscr], .vpr = all[slot.vpr] }, .sp = 0 };
    @memcpy(&popped.frame, all[0..frame.words]);
    @memcpy(&popped.fp.s, all[slot.s0..slot.fpscr]);
    const pad: u32 = if (all[frame.slot.xpsr] & frame.realigned != 0) 4 else 0;
    popped.sp = (at +% size) | pad;
    return popped;
}
