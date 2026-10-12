//! The app's shipped board and panel profiles (RA8EMU-1152), the catalog
//! the Board menu lists. The GUI module imports neither ra8_board nor
//! ra8_chip (RA8EMU-984): the build hands this module the shipped board
//! file as an anonymous import, and the panel catalog names the set the
//! session's own panel table resolves. A panel added to src/board/panels/
//! joins both lists.
const std = @import("std");

/// The one shipped board, and the default when nothing is saved.
pub const default_board = "ek_ra8d2";

/// The shipped board's profile text. A pick composes a session profile
/// from it, rewriting or dropping its panel line. The session's own copy
/// (src/board/ek_ra8d2.board) is the source of truth: a change there is
/// copied here, since the GUI module imports neither ra8_board nor
/// ra8_chip (RA8EMU-984).
pub const board_text =
    \\# RA8D2 EK development board, profile format version 1.
    \\version=1
    \\ospi=size:268435456,width:8,clock_hz:166666667,latency_cycles:8,burst:incrementing16
    \\sdram=size:134217728,width:32,clock_hz:133000000,latency_cycles:3,burst:incrementing16
    \\memory_window_cycles=1000000
    \\led=P600,0x001F,LED1 BLUE
    \\led=P303,0x07E0,LED2 GREEN
    \\led=PA07,0xF800,LED3 RED
    \\switch=P009,SW1
    \\switch=P008,SW2
    \\panel=ek_ra8d2
    \\companion=c6@uart:sci2
    \\
;

pub const Panel = struct {
    /// The stem the board file's panel= line names, empty meaning the
    /// board's own panel, "none" meaning no panel at all.
    stem: []const u8,
    label: []const u8,
};

/// What the session's panel table (src/board/panels/) resolves, in menu
/// order: the board's own panel first, then the shipped samples.
pub const panels = [_]Panel{
    .{ .stem = "", .label = "Board's own panel" },
    .{ .stem = "ek_ra8d2", .label = "EK-RA8D2 panel" },
    .{ .stem = "sample_480x272", .label = "Sample TFT 480x272" },
    .{ .stem = "sample_800x480", .label = "Sample TFT 800x480" },
    .{ .stem = "sample_eink", .label = "Sample e-ink" },
};

/// The panel a saved or picked stem names, or null when none matches.
pub fn panel(stem: []const u8) ?*const Panel {
    for (&panels) |*entry| {
        if (std.mem.eql(u8, entry.stem, stem)) return entry;
    }
    return null;
}
