//! One line per SD command, for reading what a firmware asks the card to do.
//!
//! The card model answers a command and moves on, so the only way to see the
//! order a driver issues them in was to put a print inside the model and take
//! it out again. That happened twice while chasing the e-reader apps' mount
//! and provision walls, which is the second caller AGENTS.md asks for before a
//! seam goes in.
//!
//! The formatting lives here rather than in the card so it can be tested
//! without stdio: `line()` fills a caller-owned buffer and hands back the
//! slice it used. The card owns the decision to print and the buffer it prints
//! from; this file owns what the text says.

const std = @import("std");

/// Widest line `line()` can produce, so a caller can size its buffer from a
/// name instead of a guess.
pub const width: usize = 48;

/// A caller-owned buffer wide enough for any line this module writes.
pub const Buffer = [width]u8;

/// One command as text: the index, its argument, and whether CMD55 came first.
///
/// An ACMD is written with its `A` prefix because CMD41 and ACMD41 are
/// different commands with the same index, and a trace that hid the
/// difference would be the one thing a reader most needs from it.
pub fn line(buf: *Buffer, index: u8, arg: u32, app: bool) []const u8 {
    const prefix: []const u8 = if (app) "ACMD" else "CMD";
    return std.fmt.bufPrint(buf, "sd {s}{d} arg 0x{X:0>8}", .{ prefix, index, arg }) catch buf[0..0];
}
