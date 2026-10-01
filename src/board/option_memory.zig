//! Option-setting memory, read once the image is in place.
//!
//! The boot ROM reads OFS0 before the first instruction runs, so the board
//! reads it at the same point: after the image is loaded, before the core
//! starts. An address the image left unwritten reads as an erased part.
const iwdt = @import("../periph/iwdt/iwdt.zig");

const Board = @import("board.zig").Board;

/// Hand the image's OFS0 word to the blocks it configures at reset.
pub fn apply(self: *Board, core: anytype) void {
    const word = core.readWord(iwdt.ofs0.address) catch iwdt.ofs0.erased;
    self.heartbeat.applyOptionWord(word);
}
