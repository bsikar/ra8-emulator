//! The floating-point state a core carries: the S/D register bank and
//! FPSCR. The FPU semantics stay pure functions over these values; the
//! instruction groups read operands from here and write results back.
const Bank = @import("bank.zig").Bank;
const Fpscr = @import("fpscr.zig").Fpscr;

pub const State = struct {
    bank: Bank = .{},
    fpscr: Fpscr = .{},
};
