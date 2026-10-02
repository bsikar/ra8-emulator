//! The MVE share of the test root: every test file under
//! tests/core/cpu/mve/, pulled in by tests/all.zig.
test {
    _ = @import("qreg_test.zig");
    _ = @import("predicate_test.zig");
    _ = @import("vpt_test.zig");
    _ = @import("int_test.zig");
    _ = @import("int_vectors_test.zig");
    _ = @import("int_shift_test.zig");
    _ = @import("int_shift_vectors_test.zig");
    _ = @import("int_width_test.zig");
    _ = @import("int_width_vectors_test.zig");
    _ = @import("int_insert_test.zig");
    _ = @import("int_insert_vectors_test.zig");
    _ = @import("reduce_test.zig");
    _ = @import("reduce_vectors_test.zig");
    _ = @import("reduce_minmax_test.zig");
    _ = @import("reduce_minmax_vectors_test.zig");
    _ = @import("int_mul_test.zig");
    _ = @import("int_mul_vectors_test.zig");
    _ = @import("compare_test.zig");
    _ = @import("compare_vectors_test.zig");
    _ = @import("bit_reverse_test.zig");
    _ = @import("bit_reverse_vectors_test.zig");
    _ = @import("contiguous_test.zig");
    _ = @import("contiguous_vectors_test.zig");
    _ = @import("contiguous_wide_vectors_test.zig");
    _ = @import("gather_test.zig");
    _ = @import("gather_vectors_test.zig");
    _ = @import("gather64_vectors_test.zig");
    _ = @import("gather_imm_vectors_test.zig");
    _ = @import("interleave_test.zig");
    _ = @import("interleave_vectors_test.zig");
    _ = @import("eci_test.zig");
}
