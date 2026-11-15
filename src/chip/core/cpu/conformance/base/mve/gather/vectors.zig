//! Conformance vectors for the decode group `mve.gather` (RA8EMU-278): the
//! gather loads VLDRB/VLDRH/VLDRW [Rn, Qm{, uxtw #n}] and scatter stores
//! VSTRB/VSTRH/VSTRW [Rn, Qm{, uxtw #n}]. Expected values are worked from
//! the Arm ARM (DDI0553) pseudocode: element e touches Rn + (UInt(Qm[e])
//! << (os ? msize : 0)), with Qm read at the element width. A load sign- or
//! zero-extends the memory value, a store writes the element's low bytes.
//! Each access is a MemA access that faults (unaligned, or unmapped outside
//! the RAM) before it reaches memory: a faulting load leaves Qd and VPR
//! alone, and a faulting scatter keeps what it already wrote. An element is
//! active when its first byte is (VPT, the loop tail, EPSR.ECI); a load
//! zeroes inactive elements and keeps the beats ECI says already ran, a
//! store skips them, and an inactive element never faults. Rn is never
//! written. The RAM window at 0x2000_0200 starts as `fill`. A load whose Qd
//! is Qm, a PC base, a store with U set, the size combinations the
//! architecture leaves undefined, element size 11 (mve.gather64), Q8 and
//! above, flipped fixed bits and the 16-bit space are unclaimed.
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
    vec("a load whose qd is qm is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4F04, .base = 0x20000200 }, none),
    vec("a pc base is unclaimed", .{ .hw1 = 0xFC9F, .hw2 = 0x4F06, .base = 0x00000000 }, none),
    vec("a store with u set is unclaimed", .{ .hw1 = 0xFC81, .hw2 = 0x4F06, .base = 0x20000200 }, none),
    vec("a signed load that does not widen is unclaimed", .{ .hw1 = 0xEC91, .hw2 = 0x4F56, .base = 0x20000200 }, none),
    vec("memory wider than the element is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4EC6, .base = 0x20000200 }, none),
    vec("uxtw with byte memory is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4F07, .base = 0x20000200 }, none),
    vec("element size 11 belongs to the 64-bit group", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFCD1, .hw2 = 0x4F06, .base = 0x20000200 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4F26, .base = 0x20000200 }, none),
    vec("hw1 bit 5 set is unclaimed", .{ .hw1 = 0xFCB1, .hw2 = 0x4F06, .base = 0x20000200 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x5F06, .base = 0x20000200 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4F06, .base = 0x20000200, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
