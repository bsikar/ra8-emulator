//! The floating-point state a core carries: the S/D register bank, FPSCR,
//! and the MVE predication register VPR, which Armv8.1-M keeps in the FP
//! context so it is stacked and lazily preserved with the rest. The FPU semantics stay pure functions over these values; the
//! instruction groups read operands from here and write results back.
const Bank = @import("bank.zig").Bank;
const Fpscr = @import("fpscr.zig").Fpscr;
const Vpr = @import("../mve/predicate.zig").Vpr;
const Context = @import("context.zig").Context;

pub const State = struct {
    bank: Bank = .{},
    fpscr: Fpscr = .{},
    vpr: Vpr = .{},
    /// FPCCR, FPCAR and FPDSCR.
    context: Context = .{},
};
