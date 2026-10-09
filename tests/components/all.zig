//! Tests for the parts outside the MCU: one directory per part, as in
//! src/components.

test {
    _ = @import("camera_ov5640/ov5640_sccb_test.zig");
    _ = @import("expander_pi4ioe/pi4ioe_test.zig");
    _ = @import("touch_gt911/gt911_test.zig");
    _ = @import("touch_gt911/input_script_test.zig");
    _ = @import("imu_lsm6dso/lsm6dso_test.zig");
    _ = @import("gauge_max17048/max17048_test.zig");
    _ = @import("usb_loop_cable/cable_test.zig");
    _ = @import("usb_loop_cable/cable_bulk_test.zig");
    _ = @import("user_switch/user_switch_test.zig");
    _ = @import("eth_phy/phy_test.zig");
    _ = @import("eth_phy/peer_test.zig");
}
