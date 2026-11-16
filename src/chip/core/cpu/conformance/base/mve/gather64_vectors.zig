//! Conformance vectors for the decode group `mve_gather64` (RA8EMU-278):
//! the 64-bit gather VLDRD.U64 and scatter VSTRD.64 [Rn, Qm{, uxtw #3}].
//! Expected values are worked from the Arm ARM (DDI0553) pseudocode: each
//! doubleword moves as two word beats, the low word of its Qm doubleword
//! (scaled by 8 under uxtw #3) offsets Rn, the high beat sits four bytes
//! above, and only the low 32 bits of the offset reach the address. Each
//! beat is a word MemA access that faults (unaligned, or unmapped outside
//! the RAM) before reaching memory: a faulting load leaves Qd and VPR
//! alone, and a faulting scatter keeps what it already wrote. Each beat
//! runs under its own predicate bit (VPT, the loop tail, EPSR.ECI); a load
//! zeroes inactive beats and keeps the ones ECI says already ran, a store
//! skips them, and an inactive beat never faults. Rn is never written. The
//! RAM window at 0x2000_0200 starts as `fill`. A load whose Qd is Qm, a PC
//! base, a load with U clear, a store with U set, Q8 and above, flipped
//! fixed bits and the 16-bit space are unclaimed.
const defs = @import("gather64_types.zig");

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

const forms_01 = @import("gather64_forms_01.zig");
const forms_02 = @import("gather64_forms_02.zig");

const forms = forms_01.values ++
    forms_02.values;

const predicated_01 = @import("gather64_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("a load whose qd is qm is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4FD4, .base = 0x20000200 }, none),
    vec("a pc base is unclaimed", .{ .hw1 = 0xFC9F, .hw2 = 0x4FD6, .base = 0x00000000 }, none),
    vec("a load with u clear has no signed form", .{ .hw1 = 0xEC91, .hw2 = 0x4FD6, .base = 0x20000200 }, none),
    vec("a store with u set is unclaimed", .{ .hw1 = 0xFC81, .hw2 = 0x4FD6, .base = 0x20000200 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFCD1, .hw2 = 0x4FD6, .base = 0x20000200 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4FF6, .base = 0x20000200 }, none),
    vec("hw1 bit 5 set is unclaimed", .{ .hw1 = 0xFCB1, .hw2 = 0x4FD6, .base = 0x20000200 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x5FD6, .base = 0x20000200 }, none),
    vec("hw2 bit 4 clear is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4FC6, .base = 0x20000200 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
