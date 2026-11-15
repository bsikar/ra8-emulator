//! Conformance vectors for the decode group `mve.vld_il` (RA8EMU-278): the
//! interleaving VLD20/VLD21, VLD40..VLD43, VST20/VST21 and VST40..VST43
//! {Qd..Qd+n-1}, [Rn]{!}. Expected values are worked from the Arm ARM
//! (DDI0553) pseudocode: each pattern moves four words, one per beat, at
//! the pattern's byte offsets from Rn, and memory element j of the 32 or 64
//! bytes belongs to register j mod n, element j / n. Each beat checks
//! alignment to the element size (MemA) and faults before it reaches
//! memory, unmapped outside the RAM: a faulting load leaves the registers
//! and Rn alone, a faulting store keeps what it already wrote. The
//! instructions are not predicated and leave VPR alone; beats EPSR.ECI marks
//! done are skipped. Writeback adds 32 (VLD2/VST2) or 64 (VLD4/VST4) to Rn.
//! The RAM window at 0x2000_0200 starts as `fill`. Q8 and above, a list past
//! Q7, size 11, a pattern past the list, a PC base, SP with writeback,
//! flipped fixed bits and the 16-bit space are unclaimed.
const defs = @import("vld_il_types.zig");

const vector = defs.vector;
pub const Fault = defs.Fault;
pub const In = defs.In;
pub const Out = defs.Out;
pub const window = defs.window;
pub const fill = defs.fill;
pub const none = defs.none;

pub const all = forms ++ predicated ++ unclaimed;

const forms_01 = @import("vld_il_forms_01.zig");
const forms_02 = @import("vld_il_forms_02.zig");
const forms_03 = @import("vld_il_forms_03.zig");

const forms = forms_01.values ++
    forms_02.values ++
    forms_03.values;

const predicated_01 = @import("vld_il_predicated_01.zig");

const predicated = predicated_01.values;

const unclaimed_01 = @import("vld_il_unclaimed_01.zig");

const unclaimed = unclaimed_01.values;

pub const covered = vector.encodingsOf(In, Out, &all);
