//! The host webcam source's parts (RA8EMU-506): the consent gate, the
//! V4L2 ABI it speaks, the capture-format negotiation and the open node.
pub const consent = @import("webcam_consent.zig");
pub const v4l2 = @import("v4l2_abi.zig");
pub const negotiate = @import("v4l2_negotiate.zig");
pub const device = @import("v4l2_device.zig");
