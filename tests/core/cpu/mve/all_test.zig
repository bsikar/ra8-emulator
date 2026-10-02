//! The MVE share of the test root: every test file under
//! tests/core/cpu/mve/, pulled in by tests/all.zig.
test {
    _ = @import("qreg_test.zig");
    _ = @import("predicate_test.zig");
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
    _ = @import("int_mul_test.zig");
    _ = @import("int_mul_vectors_test.zig");
}
