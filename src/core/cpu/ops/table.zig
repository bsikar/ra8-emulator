//! The decode table: every instruction group the Zig core knows, in the order
//! the decoder tries them.
//!
//! This is the one registration point. A group is a file under
//! src/core/cpu/ops/ holding a `pub const group: op.Group`, plus one line in
//! this list. Groups must not claim each other's encodings; the first one that
//! answers wins, so an overlap is a bug in the group, not an ordering choice.
const op = @import("../op.zig");

pub const groups = [_]op.Group{
    @import("hint.zig").group,
    @import("barrier.zig").group,
    @import("push_pop.zig").group,
    @import("sp_arith.zig").group,
    @import("ldr_literal.zig").group,
    @import("ldst_imm.zig").group,
    @import("ldst_reg.zig").group,
    @import("ldm_stm.zig").group,
    @import("shift_imm.zig").group,
    @import("add_sub.zig").group,
    @import("dp_reg.zig").group,
    @import("special_data.zig").group,
    @import("cps.zig").group,
    @import("cbz.zig").group,
    @import("extend.zig").group,
    @import("reverse.zig").group,
    @import("it.zig").group,
    @import("branch.zig").group,
    @import("mov_wide.zig").group,
    @import("divide.zig").group,
    @import("imm_logic.zig").group,
    @import("imm_arith.zig").group,
    @import("branch_wide.zig").group,
    @import("ldst_wide.zig").group,
};
