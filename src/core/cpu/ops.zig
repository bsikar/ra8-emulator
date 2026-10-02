//! The instruction groups under src/core/cpu/ops/, by name, so tests and
//! tools reach each one as ra8.core.cpu.ops.<group>. The decode order lives
//! in ops/table.zig, not here.

pub const hint = @import("ops/hint.zig");
pub const ldr_literal = @import("ops/ldr_literal.zig");
pub const ldst_imm = @import("ops/ldst_imm.zig");
pub const ldst_reg = @import("ops/ldst_reg.zig");
pub const ldm_stm = @import("ops/ldm_stm.zig");
pub const ldst_wide = @import("ops/ldst_wide.zig");
pub const shift_imm = @import("ops/shift_imm.zig");
pub const add_sub = @import("ops/add_sub.zig");
pub const dp_reg = @import("ops/dp_reg.zig");
pub const special_data = @import("ops/special_data.zig");
pub const barrier = @import("ops/barrier.zig");
pub const branch = @import("ops/branch.zig");
pub const mov_wide = @import("ops/mov_wide.zig");
pub const divide = @import("ops/divide.zig");
pub const dp_shifted = @import("ops/dp_shifted.zig");
pub const imm_fields = @import("ops/imm_fields.zig");
pub const imm_logic = @import("ops/imm_logic.zig");
pub const imm_arith = @import("ops/imm_arith.zig");
pub const branch_wide = @import("ops/branch_wide.zig");
pub const cps = @import("ops/cps.zig");
pub const cbz = @import("ops/cbz.zig");
pub const extend = @import("ops/extend.zig");
pub const reverse = @import("ops/reverse.zig");
pub const it = @import("ops/it.zig");
pub const push_pop = @import("ops/push_pop.zig");
pub const sp_arith = @import("ops/sp_arith.zig");
pub const table = @import("ops/table.zig");
