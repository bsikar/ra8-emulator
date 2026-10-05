//! The host webcam source's parts (RA8EMU-506): the consent gate, the
//! V4L2 ABI it speaks, the capture-format negotiation, the open node and
//! the frame source over it.
pub const consent = @import("webcam_consent.zig");
pub const privacy = @import("webcam_privacy.zig");
pub const v4l2 = @import("v4l2_abi.zig");
pub const negotiate = @import("v4l2_negotiate.zig");
pub const device = @import("v4l2_device.zig");
pub const stream = @import("v4l2_stream.zig");
pub const source = @import("webcam_source.zig");
pub const opener = @import("webcam_open.zig");
pub const mf = @import("mf_abi.zig");
pub const mf_com = @import("mf_com.zig");
