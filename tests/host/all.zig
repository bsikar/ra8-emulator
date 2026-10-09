//! The host adapter tests (src/host).
test {
    _ = @import("host_console_test.zig");
    _ = @import("host_read_test.zig");
    _ = @import("camera/pipe_windows_test.zig");
    _ = @import("camera/av_delegate_test.zig");
    _ = @import("camera/ppm_decode_test.zig");
    _ = @import("camera/bmp_decode_test.zig");
    _ = @import("camera/png_decode_test.zig");
    _ = @import("camera/y4m_frame_test.zig");
    _ = @import("camera/pipe_frame_test.zig");
    _ = @import("camera/av_frame_test.zig");
    _ = @import("camera/av_info_plist_test.zig");
    _ = @import("camera/av_objc_test.zig");
    _ = @import("camera/av_permission_test.zig");
    _ = @import("camera/av_session_test.zig");
    _ = @import("camera/mf_abi_test.zig");
    _ = @import("camera/mf_com_test.zig");
    _ = @import("camera/mf_open_test.zig");
    _ = @import("camera/v4l2_device_test.zig");
    _ = @import("camera/v4l2_negotiate_test.zig");
    _ = @import("camera/v4l2_stream_test.zig");
    _ = @import("camera/webcam_consent_test.zig");
    _ = @import("camera/webcam_privacy_test.zig");
    _ = @import("camera/y4m_header_test.zig");
}
