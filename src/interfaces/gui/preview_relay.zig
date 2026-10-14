//! The camera preview across two threads (session_worker.zig). The board's
//! camera source belongs to the thread that steps the board, so the shell
//! cannot sample it itself: it asks, the session's thread copies the frame
//! at its next turn, and the shell draws the last copy it was handed.
const std = @import("std");
const shell_camera = @import("shell/camera/camera.zig");

const Frame = shell_camera.PreviewFrame;

pub const Relay = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    /// The shell wants a fresh frame.
    wanted: std.atomic.Value(bool) = .init(false),
    width: u32 = 0,
    height: u32 = 0,
    /// The session's copy, under `mutex`.
    kept: std.ArrayListUnmanaged(u8) = .empty,
    /// The shell's own copy of `kept`, which it reads without the lock.
    shown: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Relay) void {
        self.kept.deinit(self.allocator);
        self.shown.deinit(self.allocator);
    }

    /// The session's thread: keep `frame` if the shell asked since the last.
    pub fn offer(self: *Relay, frame: ?Frame) void {
        if (!self.wanted.swap(false, .acq_rel)) return;
        const fresh = frame orelse return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.kept.resize(self.allocator, fresh.pixels.len) catch return;
        @memcpy(self.kept.items, fresh.pixels);
        self.width = fresh.width;
        self.height = fresh.height;
    }

    /// The shell: ask for a fresh frame and take the last one kept, or null
    /// before the first.
    pub fn latest(self: *Relay) ?Frame {
        self.wanted.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.kept.items.len == 0) return null;
        self.shown.resize(self.allocator, self.kept.items.len) catch return null;
        @memcpy(self.shown.items, self.kept.items);
        return .{ .width = self.width, .height = self.height, .pixels = self.shown.items };
    }
};
