//! Connect board observations to the core-addressed session event stream (RA8EMU-192).
const Board = @import("board.zig").Board;
const api = @import("../debug/session_api.zig");

/// Attach the non-blocking event sources for one board/core pair.
pub fn attach(board: *Board, session: *api.Session, core: api.Core) void {
    session.attachTimeBase(&board.time.base);
    board.pins.observeEvents(session.event_sources.gpioTap(core));
    board.event_sink = session.event_sources.boardEventSink(core);
    board.serial.tap = session.event_sources.uartTap(core);
}
