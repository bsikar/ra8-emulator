//! The console line a run waits on: `--until TEXT`.
//!
//! The bench's `uart_scrape` mode ends a run as soon as the line it expects
//! has been printed. Here the run otherwise goes on to its whole modelled
//! window, and a firmware that idles in a busy-wait delay after printing
//! its verdict (reflow_webp_demo spins on DWT_CYCCNT every frame) burns
//! that window an instruction at a time. `--until` ends it the way the bench
//! does: the first finished console line that contains TEXT ends the run
//! immediately after the instruction that completed that line.
//!
//! A line is matched when it finishes, from the console sink. The stop
//! lands between instructions. The text is a plain substring, as
//! the confs' HIL_EXPECT is (it carries `+` and `.` literally).
const std = @import("std");

pub const Until = struct {
    /// The text a finished line has to contain. Empty matches nothing.
    needle: []const u8,
    /// A finished line contained it.
    seen: bool = false,
    /// The run ended because of it, which the caller can ask afterwards.
    reached: bool = false,

    /// Hand over one finished console line.
    pub fn line(self: *Until, text: []const u8) void {
        if (self.needle.len == 0) return;
        if (std.mem.indexOf(u8, text, self.needle) != null) self.seen = true;
    }

    /// Does the run end at this boundary?
    pub fn met(self: *Until) bool {
        if (!self.seen) return false;
        self.reached = true;
        return true;
    }
};
