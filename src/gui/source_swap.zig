//! Hands a newly opened camera source from the window to the engine
//! (RA8EMU-227). The window opens the pick on its own thread (a webcam can
//! take a while) and posts it; the engine installs it where the CEU reads
//! at its next park, so the board's source is only ever written on the
//! engine's thread. A post that lands before the last one was taken
//! closes the waiting one: the newest pick wins.
const std = @import("std");
const FrameSource = @import("camera_switch.zig").FrameSource;

pub const SourceSwap = struct {
    mutex: std.Thread.Mutex = .{},
    pending: ?FrameSource = null,

    /// Window side: hand `next` over, closing any pick still waiting.
    pub fn post(self: *SourceSwap, next: FrameSource) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending) |*waiting| waiting.close();
        self.pending = next;
    }

    /// Engine side: close what `source` points at and install the waiting
    /// pick there. False when nothing was waiting.
    pub fn take(self: *SourceSwap, source: *FrameSource) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const next = self.pending orelse return false;
        self.pending = null;
        source.close();
        source.* = next;
        return true;
    }

    /// A pick the engine never took is closed with the window.
    pub fn deinit(self: *SourceSwap) void {
        if (self.pending) |*waiting| waiting.close();
        self.pending = null;
    }
};
