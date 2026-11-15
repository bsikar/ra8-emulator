//! Conformance vectors for the decode group `mve_gather_imm` (RA8EMU-278):
//! the vector-base VLDRW.U32, VLDRD.U64, VSTRW.32 and VSTRD.64
//! [Qm, #imm]{!}. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: each Qm word (the even word of each doubleword pair for the
//! 64-bit forms) is a base moved by imm7 scaled by 4 (or 8), a doubleword's
//! high beat sits four bytes above, and with writeback every moved address,
//! predicated or not, replaces its Qm word. Each beat is a word MemA access
//! that faults (unaligned, or unmapped outside the RAM) before reaching
//! memory: a fault leaves Qd, Qm and VPR alone, and a faulting scatter
//! keeps what it already wrote. Each beat runs under its own predicate bit
//! (VPT, the loop tail, EPSR.ECI); a load zeroes inactive beats, a store
//! skips them, an inactive beat never faults, and the beats ECI says
//! already ran keep their old Qd and Qm. The RAM window at 0x2000_0200
//! starts as `fill`. A load whose Qd is Qm, Q8 and above, flipped fixed
//! bits and the 16-bit space are unclaimed.
const defs = @import("imm_types.zig");

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

const forms_01 = @import("imm_forms_01.zig");
const forms_02 = @import("imm_forms_02.zig");

const forms = forms_01.values ++
    forms_02.values;

const predicated_01 = @import("imm_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("a load whose qd is qm is unclaimed", .{ .hw1 = 0xFDB6, .hw2 = 0x7E01 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFDD6, .hw2 = 0x5E01 }, none),
    vec("hw2 bit 7 set would name q8 and is unclaimed", .{ .hw1 = 0xFD96, .hw2 = 0x5E81 }, none),
    vec("hw1 bit 0 set is unclaimed", .{ .hw1 = 0xFD97, .hw2 = 0x5E01 }, none),
    vec("hw1 bit 8 clear is unclaimed", .{ .hw1 = 0xFC96, .hw2 = 0x5E01 }, none),
    vec("hw2 bit 12 clear is unclaimed", .{ .hw1 = 0xFD96, .hw2 = 0x4E01 }, none),
    vec("hw2 bit 9 clear is unclaimed", .{ .hw1 = 0xFD96, .hw2 = 0x5C01 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFD96, .hw2 = 0x5E01, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
