//! The shell's local session (RA8EMU-1092, ADR 0004 step 6): the image's
//! session served in-process, so `ra8_gui IMAGE` starts no second process.
//! Its requests cross the worker's typed mailbox (local_native_link.zig)
//! and the worker's thread serves them; RPC over a pipe or socket is only
//! for a remote session.
const std = @import("std");
const board_camera = @import("ra8_session").board.camera;
const served_setup = @import("ra8_rpc").served_setup;

pub const LocalSession = struct {
    setup: served_setup.Served,

    /// Open `elf_path` and serve it, on the board profile `board_profile`
    /// names (RA8EMU-1152; null is the shipped default). The host and the
    /// context point into `self`, so it stays put until `deinit`.
    pub fn open(self: *LocalSession, allocator: std.mem.Allocator, io: std.Io, elf_path: []const u8, board_profile: ?[]const u8) !void {
        try self.setup.open(allocator, io, elf_path, board_profile, null);
    }

    /// Bring up cpu1 from `path` in the already-open session (RA8EMU-1192).
    pub fn openSecond(self: *LocalSession, path: []const u8) !void {
        try self.setup.openSecond(path);
    }

    /// Sample a preview frame from the board's camera source (RA8EMU-1180).
    pub fn cameraPreview(self: *LocalSession) ?board_camera.Preview {
        return board_camera.preview(self.setup.owner.board());
    }

    pub fn deinit(self: *LocalSession) void {
        self.setup.deinit();
    }
};
