//! Session RPC test registry, mirroring the session module root.
test {
    _ = @import("advance_transport_test.zig");
    _ = @import("seek_test.zig");
    _ = @import("timeline_trace_test.zig");
    _ = @import("rpc_test.zig");
    _ = @import("server_test.zig");
    _ = @import("camera_test.zig");
    _ = @import("lcd_feed_test.zig");
    _ = @import("advance_test.zig");
    _ = @import("files_test.zig");
    _ = @import("load_chunks_test.zig");
    _ = @import("stack_test.zig");
    _ = @import("rtc_test.zig");
    _ = @import("metrics_test.zig");
    _ = @import("input_test.zig");
    _ = @import("event_feed_test.zig");
    _ = @import("backtrace_test.zig");
    _ = @import("locals_test.zig");
    _ = @import("source_line_test.zig");
    _ = @import("periph_test.zig");
    _ = @import("folded_test.zig");
    _ = @import("branch_test.zig");
    _ = @import("intervene_test.zig");
    _ = @import("branch_wire_test.zig");
    _ = @import("diff_test.zig");
    _ = @import("diff_wire_test.zig");
    _ = @import("disasm_test.zig");
    _ = @import("disasm_wire_test.zig");
    _ = @import("locals_wire_test.zig");
    _ = @import("nav_rpc_test.zig");
    _ = @import("set_var_test.zig");
}
