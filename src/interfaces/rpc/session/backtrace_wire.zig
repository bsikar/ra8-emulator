//! The backtrace wire messages (RA8EMU-1125). Split out of the protocol
//! vocabulary file so the file stays small; rpc.zig re-exports these under
//! the same names.
const proto = @import("rpc.zig");

/// A core's call chain, innermost first (RA8EMU-1125): `count` frames in
/// `frames`, each a StackFrame as backtrace_wire.zig packs it.
pub const Backtrace = struct {
    core: proto.Core,
    count: u8,
    frames: []const u8,
    pub const max_len = .{ .frames = backtrace_bytes };
};

/// One frame of a Backtrace. `interrupted` is 1 when an exception sits
/// between this frame and the one inside it; `line` is 0 and `file` empty
/// where the line table does not cover the frame, and `name` empty where
/// no symbol does.
pub const StackFrame = struct {
    pc: u32,
    interrupted: u8,
    offset: u32,
    line: u32,
    name: []const u8,
    file: []const u8,
    pub const max_len = .{ .name = frame_name_cap, .file = frame_file_cap };
};

/// The most frames a Backtrace carries, and the characters a frame's
/// function and file name keep.
pub const backtrace_frames = 32;
pub const frame_name_cap = 40;
pub const frame_file_cap = 32;
/// One frame's widest encoding plus the length byte before it.
pub const frame_bytes = 1 + 4 + 1 + 4 + 4 + 4 + frame_name_cap + 4 + frame_file_cap;
pub const backtrace_bytes = backtrace_frames * frame_bytes;
