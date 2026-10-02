//! MVE contiguous loads and stores, VLDRB/VLDRH/VLDRW and VSTRB/VSTRH/
//! VSTRW with elements as wide as memory (RA8EMU-25), from their
//! pseudocode in the Arm ARM (DDI0553). The offset is imm7 scaled by the
//! element size; P picks pre-indexing (the offset address is the start)
//! over post-indexing (the base is), and W writes the offset address back
//! to Rn whatever the predicate says. Element e sits at start + e * size.
//! A load zeroes the elements the predicate leaves inactive and a store
//! skips them, touching no memory for either.
const qreg = @import("qreg.zig");
const predicate = @import("predicate.zig");
const Size = qreg.Size;

pub const Form = struct { base: u32, imm7: u7, size: Size, add: bool, pre: bool, wback: bool };

pub const Plan = struct { start: u32, wback: ?u32 };

/// Bytes per element.
pub fn bytes(size: Size) u3 {
    return @intCast(qreg.bits(size) / 8);
}

/// Where the transfer starts and what Rn becomes.
pub fn plan(f: Form) Plan {
    const offset: u32 = @as(u32, f.imm7) * bytes(f.size);
    const moved = if (f.add) f.base +% offset else f.base -% offset;
    return .{ .start = if (f.pre) moved else f.base, .wback = if (f.wback) moved else null };
}

/// The address of element `e`.
pub fn address(start: u32, size: Size, e: u8) u32 {
    return start +% @as(u32, e) * bytes(size);
}

/// `loaded` with every element the mask leaves inactive cleared to zero.
pub fn zeroInactive(loaded: u128, mask: u16, size: Size) u128 {
    var out: u128 = 0;
    for (0..qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        if (predicate.active(mask, size, e)) out = qreg.setElem(out, size, e, qreg.elem(loaded, size, e));
    }
    return out;
}
