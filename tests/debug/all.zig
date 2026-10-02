//! The debugger's tests, listed in one place so tests/all.zig carries a
//! single line for them. Every file under tests/debug/ is reached from here,
//! directly or through a file listed here.
test {
    _ = @import("disasm_test.zig");
    _ = @import("symbols_test.zig");
    _ = @import("breakpoint_test.zig");
    _ = @import("break_table_test.zig");
    _ = @import("stop_machine_test.zig");
    _ = @import("watch_table_test.zig");
    _ = @import("call_decode_test.zig");
    _ = @import("step_hook_test.zig");
    _ = @import("step_hook_image_test.zig");
    _ = @import("commands_test.zig");
    _ = @import("session_test.zig");
    _ = @import("script_test.zig");
    _ = @import("session_cores_test.zig");
    _ = @import("session_image_cores_test.zig");
    _ = @import("session_loop_test.zig");
    _ = @import("break_hook_test.zig");
    _ = @import("break_list_test.zig");
    _ = @import("pc_hits_test.zig");
    _ = @import("watchpoint_test.zig");
    _ = @import("spacing_test.zig");
    _ = @import("tally_test.zig");
    _ = @import("taken_in_test.zig");
    _ = @import("place_test.zig");
    _ = @import("registers_test.zig");
    _ = @import("hotspots_test.zig");
    _ = @import("functions_test.zig");
    _ = @import("rsp_packet_test.zig");
    _ = @import("rsp_features_test.zig");
    _ = @import("rsp_dispatch_test.zig");
    _ = @import("fpb_test.zig");
}
