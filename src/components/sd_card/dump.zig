//! One card block as readable hex, for seeing what a firmware left behind.
//!
//! `--trace-sd` says which blocks a driver touched; it cannot say what it
//! wrote. Chasing the e-reader apps' provision wall needs both: the trace
//! shows a single write of the root directory sector, and the only way to
//! tell whether the entry in it names a cluster is to read the bytes back.
//!
//! The formatting lives here rather than in the report so it can be tested
//! without a card: `row()` fills a caller-owned buffer and hands back the
//! slice it used. A row of nothing but zeros is worth skipping rather than
//! printing, because a 512-byte block of a freshly formatted volume is
//! mostly zeros and the few rows that carry data are the whole point;
//! `blank()` is that test, and the caller decides what to do about it.

const std = @import("std");

/// Bytes per printed row. Sixteen is what a hex dump has always been, and it
/// keeps a row inside a terminal width alongside its offset and text column.
pub const row_bytes: usize = 16;

/// Widest row `row()` can produce, so a caller can size its buffer from a
/// name instead of a guess.
pub const width: usize = 96;

/// A caller-owned buffer wide enough for any row this module writes.
pub const Buffer = [width]u8;

/// Whether a row is nothing but zeros, and so not worth a line of output.
pub fn blank(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// One row: its offset in the block, the bytes as hex, then the same bytes as
/// text with anything unprintable shown as a dot. A short final row prints
/// the bytes it has and pads the hex column so the text column still lines up.
pub fn row(buf: *Buffer, offset: usize, bytes: []const u8) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    out.print("  {X:0>4}  ", .{offset}) catch return buf[0..0];
    for (0..row_bytes) |index| {
        if (index < bytes.len) {
            out.print("{X:0>2} ", .{bytes[index]}) catch return buf[0..0];
        } else {
            out.writeAll("   ") catch return buf[0..0];
        }
    }
    out.writeAll(" |") catch return buf[0..0];
    for (bytes) |byte| {
        const shown: u8 = if (std.ascii.isPrint(byte)) byte else '.';
        out.writeByte(shown) catch return buf[0..0];
    }
    out.writeByte('|') catch return buf[0..0];
    return out.buffered();
}
