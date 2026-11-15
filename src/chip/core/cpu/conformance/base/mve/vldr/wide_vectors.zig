//! Conformance vectors for the decode group `mve_vldr_wide` (RA8EMU-278):
//! the widening VLDRB.S16/U16/S32/U32 and VLDRH.S32/U32 and the narrowing
//! VSTRB.16/32 and VSTRH.32. Expected values are worked from the Arm ARM
//! (DDI0553) pseudocode: offset = imm7 scaled by the memory size,
//! offset_addr = Rn +/- offset, address = P ? offset_addr : Rn, and Rn =
//! offset_addr when W; element e sits at address + e * the memory size. A
//! load sign- or zero-extends the memory value to the element, a store
//! writes the element's low bytes. Each access is a MemA access that faults
//! (unaligned, or unmapped outside the RAM) before it reaches memory: a
//! faulting load leaves Qd, Rn and VPR alone. An element is active when its
//! first byte is (VPT, the loop tail, EPSR.ECI); a load zeroes inactive
//! elements and keeps the beats ECI says already ran, a store skips them.
//! The RAM window at 0x2000_0200 starts as `fill`. P and W both clear, a
//! store with U set, H with a halfword element, element sizes 00 and 11,
//! Q8 and above, flipped fixed bits and the 16-bit space are unclaimed.
const defs = @import("wide_types.zig");

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

const forms_01 = @import("wide_forms_01.zig");
const forms_02 = @import("wide_forms_02.zig");

const forms = forms_01.values ++
    forms_02.values;

const predicated_01 = @import("wide_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed = [_]V{
    vec("p and w both clear is another encoding", .{ .hw1 = 0xEC91, .hw2 = 0x4F00, .base = 0x20000200 }, none),
    vec("a store with u set is unclaimed", .{ .hw1 = 0xFD81, .hw2 = 0x4F00, .base = 0x20000200 }, none),
    vec("h with a halfword element is unclaimed", .{ .hw1 = 0xED99, .hw2 = 0x4E80, .base = 0x20000200 }, none),
    vec("element size 00 is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x4E00, .base = 0x20000200 }, none),
    vec("element size 11 is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x4F80, .base = 0x20000200 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEDD1, .hw2 = 0x4F00, .base = 0x20000200 }, none),
    vec("hw1 bit 9 clear is unclaimed", .{ .hw1 = 0xEB91, .hw2 = 0x4F00, .base = 0x20000200 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x5F00, .base = 0x20000200 }, none),
    vec("hw2 bit 9 clear is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x4D00, .base = 0x20000200 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x4F00, .base = 0x20000200, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
