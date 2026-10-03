//! Covers src/core/cpu/text/all.zig.
test {
    _ = @import("text_test.zig");
    _ = @import("table_test.zig");
    _ = @import("disasm_test.zig");
    _ = @import("shift_imm_test.zig");
    _ = @import("add_sub_test.zig");
    _ = @import("dp_reg_test.zig");
    _ = @import("special_data_test.zig");
    _ = @import("extend_test.zig");
    _ = @import("reverse_test.zig");
}
