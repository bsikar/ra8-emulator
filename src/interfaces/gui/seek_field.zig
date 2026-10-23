//! The time bar's seek field: type a target the transport's seek grammar
//! names ("12.402s", "+500ms", "25%", "frame 12", "bm main_loop") and
//! Enter hands it to the session. The grammar is the transport's
//! (session/history/seek_target.zig), not a copy of it: the field refuses
//! nothing in-field, and a send the link refuses keeps the typed text and
//! the keyboard, with the refusal named in the status bar.
const std = @import("std");
const hex_entry = @import("ui/hex_entry.zig");
const time_bar_capture = @import("time/bar_capture.zig");
const status_bar = @import("status/bar.zig");
const session_link = @import("session_link.zig");
const shell_run = @import("shell/run.zig");

const Status = status_bar.Status;
const Link = session_link.Link;
const Run = shell_run.Run;

pub const codes = struct {
    pub const enter: u32 = hex_entry.codes.enter;
    pub const kp_enter: u32 = 0x40000058;
    pub const escape: u32 = hex_entry.codes.escape;
    pub const backspace: u32 = hex_entry.codes.backspace;
    pub const delete: u32 = hex_entry.codes.delete;
};

/// Long enough for `arrival 2 0x08001abc`, the grammar's longest common form.
pub const max_chars: usize = 20;

pub const Outcome = enum { typing, sent, cancel };

pub const Field = struct {
    chars: [max_chars]u8 = undefined,
    len: usize = 0,
    editing: bool = false,
    fresh: bool = false,

    pub fn text(self: *const Field) []const u8 {
        return self.chars[0..self.len];
    }

    /// Prepares the field for keyboard input, starting empty: no target is
    /// in force, so there is nothing to prefill.
    pub fn startEditing(self: *Field) void {
        self.len = 0;
        self.editing = true;
        self.fresh = true;
    }

    /// Cancels editing and drops what was typed.
    pub fn cancel(self: *Field) void {
        self.len = 0;
        self.editing = false;
        self.fresh = false;
    }

    /// Keeps what a seek target is made of: printable characters. What is
    /// malformed is the transport's to name, not the field's.
    pub fn typed(self: *Field, input: []const u8) void {
        if (self.fresh) {
            self.len = 0;
            self.fresh = false;
        }
        for (input) |byte| {
            if (self.len == max_chars) return;
            if (!std.ascii.isPrint(byte)) continue;
            self.chars[self.len] = byte;
            self.len += 1;
        }
    }

    /// Enter sends the typed target and closes the field; a send the link
    /// refuses keeps the text and the keyboard. Escape drops what was
    /// typed, Backspace and Delete drop a character.
    pub fn key(self: *Field, status: *Status, run: *Run, link: *Link, code: u32) !Outcome {
        switch (code) {
            codes.enter, codes.kp_enter => {
                if (self.len == 0) {
                    self.cancel();
                    return .cancel;
                }
                try time_bar_capture.seek(status, run, link, self.text());
                self.cancel();
                return .sent;
            },
            codes.escape => {
                self.cancel();
                return .cancel;
            },
            codes.backspace, codes.delete => {
                if (self.fresh) {
                    self.len = 0;
                    self.fresh = false;
                } else {
                    self.len -|= 1;
                }
            },
            else => {},
        }
        return .typing;
    }

    /// What the field reads: the typed text while editing, else nothing
    /// (no target is in force).
    pub fn shown(self: *const Field, buf: []u8) ![]const u8 {
        if (self.editing or self.len > 0) return std.fmt.bufPrint(buf, "{s}", .{self.text()});
        return buf[0..0];
    }
};
