//! Host touches fed to the GT911 while the firmware runs (RA8EMU-343).
//!
//! `--touch @PATH` opens PATH (a file or a FIFO) without blocking, and each
//! board boundary moves the complete lines waiting on it onto the panel's
//! queue, the way host stdin reaches SCI8 under `--console`. A line is
//! "X,Y", optionally led by "down " or "move "; a drag is a run of lines,
//! one contact per frame. "up" and blank lines are accepted and add
//! nothing: this panel model reports single contacts, so a release is
//! simply the next frame with nothing armed.
const std = @import("std");
const gt911 = @import("i3c_gt911.zig");

/// Longest line kept. A longer one is dropped whole and counted.
pub const line_bytes: usize = 32;

pub const Input = struct {
    enabled: bool = false,
    fd: std.posix.fd_t = -1,
    line: [line_bytes]u8 = undefined,
    len: usize = 0,
    /// The current line ran past line_bytes and is being skipped.
    overlong: bool = false,
    /// Something has been read, so end of file now means the writer is done.
    seen: bool = false,
    /// Contacts put on the panel's queue.
    taken: u32 = 0,
    /// Lines that were not a contact, or a contact the full queue refused.
    refused: u32 = 0,

    /// Open PATH for reading without blocking, so a FIFO with no writer yet
    /// does not hold up the run.
    pub fn open(self: *Input, path: []const u8) !void {
        self.fd = std.posix.open(path, .{ .NONBLOCK = true }, 0) catch |err| {
            std.debug.print("--touch @{s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        self.enabled = true;
    }

    /// Move every complete line waiting on the descriptor onto the panel.
    /// A partial line waits for its newline. End of file stops the polling
    /// once anything has arrived; before that it is a FIFO whose writer has
    /// not opened yet, so it is asked again next boundary.
    pub fn poll(self: *Input, panel: *gt911.Panel) void {
        if (!self.enabled) return;
        var bytes: [256]u8 = undefined;
        while (true) {
            const count = std.posix.read(self.fd, &bytes) catch return;
            if (count == 0) {
                if (self.seen) self.enabled = false;
                return;
            }
            self.seen = true;
            for (bytes[0..count]) |byte| self.take(panel, byte);
        }
    }

    fn take(self: *Input, panel: *gt911.Panel, byte: u8) void {
        if (byte != '\n') {
            if (self.len == line_bytes) self.overlong = true;
            if (!self.overlong) {
                self.line[self.len] = byte;
                self.len += 1;
            }
            return;
        }
        if (self.overlong) {
            self.refused += 1;
        } else self.feedLine(panel, self.line[0..self.len]);
        self.len = 0;
        self.overlong = false;
    }

    /// One host line: a contact queued, or nothing for "up" and blanks.
    pub fn feedLine(self: *Input, panel: *gt911.Panel, raw: []const u8) void {
        var text = std.mem.trim(u8, raw, " \t\r");
        if (text.len == 0 or std.mem.eql(u8, text, "up")) return;
        for ([_][]const u8{ "down ", "move " }) |verb| {
            if (std.mem.startsWith(u8, text, verb)) text = std.mem.trimLeft(u8, text[verb.len..], " ");
        }
        const contact = parse(text) orelse {
            self.refused += 1;
            return;
        };
        panel.queue(contact) catch {
            self.refused += 1;
            return;
        };
        self.taken += 1;
    }
};

/// "X,Y" in the panel's own coordinates, or null.
pub fn parse(text: []const u8) ?gt911.Contact {
    const split = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    return .{
        .x = std.fmt.parseInt(u16, std.mem.trim(u8, text[0..split], " "), 10) catch return null,
        .y = std.fmt.parseInt(u16, std.mem.trim(u8, text[split + 1 ..], " "), 10) catch return null,
    };
}
