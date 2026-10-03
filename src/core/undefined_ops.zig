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
//!
//! WHICH IS WHY EACH SITE COUNTS ITS OWN ARRIVALS. The sweep alone cannot
//! separate an undefined encoding that sits in a literal pool from one the
//! firmware really runs, and the difference is the whole question: an image
//! can carry ten of these and execute none. So every swept site is watched
//! for the length of the run and reports how many times it was reached. A
//! site with no arrivals is data or a path not taken; a site with arrivals
//! is a run whose results downstream of it mean nothing, and the report no
//! longer calls such a run clean without qualification.
const std = @import("std");
const elf = @import("elf.zig");
const symbols = @import("../debug/symbols.zig");
const long_shift = @import("long_shift.zig");

pub const limits = struct {
    /// How many sites the report names before it stops listing them. The
    /// count is always exact; the list is for pointing objdump somewhere.
    pub const listed: usize = 6;

    /// How many sites are kept, and therefore watched for arrivals. Higher
    /// than `listed` on purpose: the list is what a reader wants to see,
    /// while every site kept here gets a hook and can prove whether it
    /// runs. Beyond this the count stays exact and the tail goes unwatched,
    /// which the report says rather than implying a silent zero.
    pub const watched: usize = 32;

    /// The low halfword of the first 32-bit Thumb encoding. Below this a
    /// halfword is a 16-bit instruction all by itself.
    pub const wide_floor: u16 = 0xE800;
};

/// One place in the image that carries an instruction the architecture
/// leaves undefined, with the encoding as it sits in the bytes.
pub const Site = struct {
    address: u32,
    encoding: u32,
    /// How many times the run reached this site. Zero means the sweep
    /// found the bytes and nothing executed them.
    runs: u32 = 0,
    /// Whether reaching this site should end the run. Off by default: the
    /// report's job is to say the run cannot be trusted, not to decide
    /// that for the reader. Turned on for every kept site by
    /// `Found.stopOnRun`, which is what `--stop-on-undefined` asks for.
    stop: bool = false,
};

/// What a sweep of one image found.
pub const Found = struct {
    count: usize = 0,
    sites: [limits.watched]Site = undefined,

    fn add(self: *Found, site: Site) void {
        if (self.count < limits.watched) self.sites[self.count] = site;
        self.count += 1;
    }

    /// Every site kept, which is what gets watched for arrivals.
    pub fn kept(self: *Found) []Site {
        return self.sites[0..@min(self.count, limits.watched)];
    }

    /// The sites actually listed in the report, which is every one of them
    /// until the list fills. `count` stays exact either way.
    pub fn listed(self: *const Found) []const Site {
        return self.sites[0..@min(self.count, limits.listed)];
    }

    /// How many of the kept sites the run actually reached.
    pub fn sitesRun(self: *const Found) usize {
        var total: usize = 0;
        for (self.sites[0..@min(self.count, limits.watched)]) |site| {
            if (site.runs > 0) total += 1;
        }
        return total;
    }

    /// Every arrival at every kept site, added up.
    pub fn arrivals(self: *const Found) u64 {
        var total: u64 = 0;
        for (self.sites[0..@min(self.count, limits.watched)]) |site| {
            total += site.runs;
        }
        return total;
    }

    /// Ask the run to end the first time it reaches any kept site.
    ///
    /// Only the kept sites can do this, because only they are watched. A
    /// site past the watch limit goes on being uncounted and cannot stop
    /// anything, which the report already says rather than implying a
    /// silent zero.
    pub fn stopOnRun(self: *Found) void {
        for (self.kept()) |*site| site.stop = true;
    }

    /// The site that ended the run, if one did.
    ///
    /// A run can reach several sites before the stop takes effect, since a
    /// core finishes the translated block it is in, so this names the
    /// first kept site that both asked to stop and was reached. Null means
    /// nothing stopped the run, whether because the flag was off or
    /// because no site was ever executed.
    pub fn stoppedAt(self: *const Found) ?Site {
        for (self.sites[0..@min(self.count, limits.watched)]) |site| {
            if (site.stop and site.runs > 0) return site;
        }
        return null;
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
///
/// Armv8.1-M takes part of that space back: the long shifts (LSLL, LSRL,
/// ASRL and the saturating forms) are ORRS-with-PC encodings to Armv7-M, and
/// the `orrs.w r3, r2, pc, lsl #2` that started this file was really
/// `lsll r2, r3, #2`. They are defined, src/core/long_shift_hook.zig runs
/// them on the Unicorn path, and they are not reported here.
pub fn shiftedPc(first: u16, second: u16) bool {
    if (long_shift.decode(first, second) != null) return false;
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
///
/// Each site carries the function it sits in, because an address alone
/// sends the reader to objdump to learn the one thing they will ask first.
/// An image with no symbol table, or an address no sized function symbol
/// covers, prints the address by itself rather than a guess.
pub fn print(out: anytype, image: elf.Image, found: Found) !void {
    if (found.count == 0) return;
    try out.print(
        "  undefined     : {d} site(s) name pc as a shifted operand, UNPREDICTABLE\n",
        .{found.count},
    );
    for (found.listed()) |site| {
        try out.print("                  0x{X:0>8} {X:0>8}", .{ site.address, site.encoding });
        if (symbols.inside(image, site.address)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        if (site.runs > 0) try out.print(" EXECUTED {d}x", .{site.runs});
        try out.print("\n", .{});
    }
    if (found.count > limits.listed) {
        try out.print("                  and {d} more\n", .{found.count - limits.listed});
        try executedPastTheList(out, image, found);
    }
    try ran(out, found);
    try stoppedThere(out, image, found);
}

/// Name the site the run stopped on, when one did.
///
/// This matters more than it looks: with `--stop-on-undefined` the run
/// ends BEFORE the undefined instruction executes, so every register and
/// every word of memory a dump prints afterwards is the machine as it
/// stood on the way in. Without this line a short run reads like a crash
/// or a budget that ran out, and the dumps beside it read like the state
/// after the damage rather than before it.
fn stoppedThere(out: anytype, image: elf.Image, found: Found) !void {
    const site = found.stoppedAt() orelse return;
    try out.print("                  run stopped at 0x{X:0>8}", .{site.address});
    if (symbols.inside(image, site.address)) |at| {
        try out.print(" {s}+0x{X}", .{ at.name, at.offset });
    }
    try out.print(", before it executed\n", .{});
}

/// Name any site that ran but sat past the end of the list.
///
/// Without this the report can say one site executed while marking none of
/// the six it listed, which sends the reader looking for a contradiction
/// that is really just a list cap. A site that ran is the one a reader
/// actually wants, so it is named wherever it sits.
fn executedPastTheList(out: anytype, image: elf.Image, found: Found) !void {
    var index: usize = limits.listed;
    while (index < @min(found.count, limits.watched)) : (index += 1) {
        const site = found.sites[index];
        if (site.runs == 0) continue;
        try out.print("                  0x{X:0>8} {X:0>8}", .{ site.address, site.encoding });
        if (symbols.inside(image, site.address)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print(" EXECUTED {d}x\n", .{site.runs});
    }
}

/// What the run did with what the sweep found.
///
/// The negative is worth printing too: an image carrying these encodings
/// that never reaches one is an image whose results are its own, and
/// saying so is what stops the sweep reading as an accusation. A run that
/// did reach one is named loudly, because every sector number, length and
/// offset computed after it is arithmetic on a program counter.
fn ran(out: anytype, found: Found) !void {
    const sites = found.sitesRun();
    if (sites == 0) {
        try out.print("                  none executed, results downstream are the image's own\n", .{});
        return;
    }
    try out.print(
        "                  {d} of them EXECUTED, {d} arrival(s): results downstream are not trustworthy\n",
        .{ sites, found.arrivals() },
    );
    if (found.count > limits.watched) {
        try out.print(
            "                  {d} site(s) past the watch limit went uncounted\n",
            .{found.count - limits.watched},
        );
    }
}
