//! The host webcam source's parts (RA8EMU-506): the consent gate, the
//! V4L2 ABI it speaks and the capture-format negotiation.
pub const consent = @import("webcam_consent.zig");
pub const v4l2 = @import("v4l2_abi.zig");
pub const negotiate = @import("v4l2_negotiate.zig");
