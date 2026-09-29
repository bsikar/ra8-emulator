//! Instructions the architecture does not define, found before they run.
//!
//! WHY THIS EXISTS. Four sessions went into a filesystem that would not
//! mount, and the answer turned out to be one instruction in the app image:
//! `orrs.w r3, r2, pc, lsl #2`, sitting where a cluster-times-four shift
//! belongs. Naming the program counter as the shifted register operand of a
//! data-processing instruction is UNPREDICTABLE in ARMv7-M and ARMv8-M, so
//! there is no right answer to execute; this core ORs in the program counter
//! and carries on, and every sector number computed downstream of it is
//! garbage. The run reported a refused read, which is true and useless.
//!
//! A core that executes an undefined instruction quietly makes its own
//! faithfulness unfalsifiable: the firmware misbehaves, and nothing
//! distinguishes "the model is wrong" from "the image asked for something
//! the architecture does not define". So the image is swept once at load
//! and the sites are named. It costs one linear pass and answers the
//! question up front instead of four sessions in.
//!
//! THE SWEEP IS BEST EFFORT AND SAYS SO. Stepping through an executable
//! segment cannot tell code from a literal pool or from data the linker
//! parked between functions, and a mis-stepped halfword can look like any
//! encoding at all. A site named here is a place to point objdump, not a
//! proof that anything executes it. Nothing here changes what runs.
const std = @import("std");
const elf = @import("elf.zig");

pub const limits = struct {
    /// How many sites the report names before it stops listing them. The
    /// count is always exact; the list is for pointing objdump somewhere.
    pub const listed: usize = 6;

    /// The low halfword of the first 32-bit Thumb encoding. Below this a
    /// halfword is a 16-bit instruction all by itself.
    pub const wide_floor: u16 = 0xE800;
};

/// One place in the image that carries an instruction the architecture
/// leaves undefined, with the encoding as it sits in the bytes.
pub const Site = struct {
    address: u32,
    encoding: u32,
};

/// What a sweep of one image found.
pub const Found = struct {
    count: usize = 0,
    sites: [limits.listed]Site = undefined,

    fn add(self: *Found, site: Site) void {
        if (self.count < limits.listed) self.sites[self.count] = site;
        self.count += 1;
    }

    /// The sites actually kept, which is every one of them until the list
    /// fills. `count` stays exact either way.
    pub fn listed(self: *const Found) []const Site {
        return self.sites[0..@min(self.count, limits.listed)];
    }
};

/// Is this halfword the first of a 32-bit Thumb instruction?
pub fn isWide(halfword: u16) bool {
    return halfword >= limits.wide_floor;
}

/// Does this 32-bit Thumb encoding name the program counter as the shifted
/// register operand of a data-processing instruction?
///
/// The class is `1110 101x xxxx xxxx  0xxx xxxx xxxx mmmm` (ARMv7-M A5.3.11,
/// data processing, shifted register). Rm is the low nibble of the second
/// halfword, and Rm = 15 is UNPREDICTABLE across the whole class: ORR, AND,
/// EOR, ADD, SUB, the lot. Bit 15 of the second halfword is zero on every
/// member, which is what keeps a coprocessor or branch encoding out.
pub fn shiftedPc(first: u16, second: u16) bool {
    if (first >> 9 != 0b1110101) return false;
    if (second & 0x8000 != 0) return false;
    return (second & 0xF) == 0xF;
}

/// Sweep every executable segment of an image for undefined encodings.
pub fn sweep(image: elf.Image) Found {
    var found = Found{};
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        if (!segment.executable()) continue;
        sweepSegment(segment, &found);
    }
    return found;
}

/// One segment, stepped the way the core steps it: a wide encoding takes
/// four bytes and everything else takes two.
fn sweepSegment(segment: elf.Segment, found: *Found) void {
    var at: usize = 0;
    while (at + 2 <= segment.bytes.len) {
        const first = std.mem.readInt(u16, segment.bytes[at..][0..2], .little);
        if (!isWide(first) or at + 4 > segment.bytes.len) {
            at += 2;
            continue;
        }
        const second = std.mem.readInt(u16, segment.bytes[at + 2 ..][0..2], .little);
        if (shiftedPc(first, second)) found.add(.{
            .address = segment.vaddr +% @as(u32, @intCast(at)),
            .encoding = @as(u32, first) << 16 | second,
        });
        at += 4;
    }
}

/// Say what the sweep found, or nothing at all when it found nothing.
pub fn print(out: anytype, found: Found) !void {
    if (found.count == 0) return;
    try out.print(
        "  undefined     : {d} site(s) name pc as a shifted operand, UNPREDICTABLE\n",
        .{found.count},
    );
    for (found.listed()) |site| {
        try out.print("                  0x{X:0>8} {X:0>8}\n", .{ site.address, site.encoding });
    }
    if (found.count > limits.listed) {
        try out.print("                  and {d} more\n", .{found.count - limits.listed});
    }
}
