//! The MVE share of the test root: every test file under
//! tests/core/cpu/mve/, pulled in by tests/all.zig.
test {
    _ = @import("qreg_test.zig");
    _ = @import("predicate_test.zig");
}
