//! The host webcam source's parts (RA8EMU-506): the consent gate, the
//! V4L2 ABI it speaks, the capture-format negotiation, the open node and
//! the frame source over it.
pub const consent = @import("../../host/camera/webcam_consent.zig");
pub const privacy = @import("../../host/camera/webcam_privacy.zig");
pub const av_permission = @import("../../host/camera/av_permission.zig");
pub const av_info_plist = @import("../../host/camera/av_info_plist.zig");
pub const av_frame = @import("../../host/camera/av_frame.zig");
pub const av_delegate = @import("../../host/camera/av_delegate.zig");
pub const av_objc = @import("../../host/camera/av_objc.zig");
pub const av_session = @import("../../host/camera/av_session.zig");
pub const av_webcam = @import("av_webcam.zig");
pub const v4l2 = @import("../../host/camera/v4l2_abi.zig");
pub const negotiate = @import("../../host/camera/v4l2_negotiate.zig");
pub const device = @import("../../host/camera/v4l2_device.zig");
pub const stream = @import("../../host/camera/v4l2_stream.zig");
pub const source = @import("webcam_source.zig");
pub const opener = @import("webcam_open.zig");
pub const mf = @import("../../host/camera/mf_abi.zig");
pub const mf_com = @import("../../host/camera/mf_com.zig");
pub const mf_open = @import("../../host/camera/mf_open.zig");
pub const mf_capture = @import("mf_capture.zig");
pub const mf_webcam = @import("mf_webcam.zig");
