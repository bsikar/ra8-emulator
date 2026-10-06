//! Changing where the CEU's pixels come from on a running board
//! (RA8EMU-795): open the spec the way `--camera-source` does (RA8EMU-525),
//! then close the old source and put the new one where the CEU reads. A
//! spec that cannot be opened leaves the old source in place.
const std = @import("std");
const Board = @import("board.zig").Board;
const registry = @import("../periph/camera/camera_registry.zig");

/// Open `spec` and install it as `board`'s camera source. Call it only on
/// the thread that steps the board.
pub fn install(board: *Board, allocator: std.mem.Allocator, spec: registry.Spec) !void {
    const next = try spec.open(allocator, &board.wire.sensor.format);
    board.capture.source.close();
    board.capture.source = next;
}
