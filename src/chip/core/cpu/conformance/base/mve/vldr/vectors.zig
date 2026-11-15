//! Conformance vectors for the decode group `mve.vldr` (RA8EMU-278): the
//! contiguous VLDRB.8, VLDRH.16, VLDRW.32 and their stores. Expected values
//! are worked from the Arm ARM (DDI0553) pseudocode: offset = imm7 << size,
//! offset_addr = Rn +/- offset, address = P ? offset_addr : Rn, and Rn =
//! offset_addr when W. Elements go lowest first, each a MemA access that
//! faults (unaligned, or unmapped outside the RAM) before it reaches memory:
//! a faulting load leaves Qd, Rn and VPR alone, and a faulting store keeps
//! what it already wrote. An element is active when its first byte is
//! (VPT, the loop tail, EPSR.ECI); a load zeroes inactive elements, keeps
//! the beats ECI says already ran, and a store skips inactive elements.
//! Rn is written back after every access is done. The RAM window at
//! 0x2000_0200 starts as `fill`. P and W both clear, a PC base, an SP base
//! with writeback, size 11, Q8 and above, flipped fixed bits and the 16-bit
//! space are unclaimed.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

const vector = defs.vector;
pub const Fault = defs.Fault;
pub const In = defs.In;
pub const Out = defs.Out;
pub const window = defs.window;
pub const fill = defs.fill;
pub const none = defs.none;

pub const all = forms ++ predicated ++ unclaimed;

const forms_01 = @import("forms_01.zig");
const forms_02 = @import("forms_02.zig");

const forms = forms_01.values ++
    forms_02.values;

const predicated_01 = @import("predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("p and w both clear is another encoding", .{ .hw1 = 0xEC91, .hw2 = 0x5E80, .base = 0x20000200 }, none),
    vec("a pc base is unclaimed", .{ .hw1 = 0xED9F, .hw2 = 0x5E80, .base = 0x00000000 }, none),
    vec("an sp base with writeback is unclaimed", .{ .hw1 = 0xEDBD, .hw2 = 0x5E80, .base = 0x20000200 }, none),
    vec("size 11 is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x5F80, .base = 0x20000200 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEDD1, .hw2 = 0x5E80, .base = 0x20000200 }, none),
    vec("hw2 bit 12 clear is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x4E80, .base = 0x20000200 }, none),
    vec("hw2 bit 9 clear is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x5C80, .base = 0x20000200 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x5E80, .base = 0x20000200, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
