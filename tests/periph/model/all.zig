//! The model tests: endpoints, the catalog, parts, requests and faults.
test {
    _ = @import("endpoint_test.zig");
    _ = @import("catalog_test.zig");
    _ = @import("parts_test.zig");
    _ = @import("request_test.zig");
    _ = @import("fault_test.zig");
    _ = @import("fault_lines_test.zig");
}
