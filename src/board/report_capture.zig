//! The camera-capture part of the end-of-run report.
//!
//! There is no sensor behind the CEU here, so the line answers the one
//! question the capture path can be wrong about: did a frame actually land
//! in the firmware's buffer, or did the run only ask for one.
const std = @import("std");

const Board = @import("board.zig").Board;

const Writer = std.fs.File.Writer;

/// Quiet unless the run armed a capture. The declined arm and the refused
/// store are the loud cases: CETCR.CPE is what the engine raised, so an
/// image that wrote it was claiming a frame it never captured.
pub fn sections(board: *Board, out: Writer) !void {
    const camera = &board.capture;
    if (camera.quiet()) return;
    try out.print(
        "CEU: {d} arm(s), {d} frame(s), last {d}x{d} ({d} bytes) synthetic gradient\n",
        .{ camera.arms, camera.frames, camera.last_width, camera.last_lines, camera.last_bytes },
    );
    if (camera.last_decline) |reason| {
        try out.print(
            "CEU: {d} arm(s) captured nothing, last because the capture was {s}\n",
            .{ camera.declined, @tagName(reason) },
        );
    }
    if (camera.faked != 0) {
        try out.print(
            "CEU: REFUSED {d} store(s) to CETCR, firmware cannot raise a capture-end flag itself\n",
            .{camera.faked},
        );
    }
}
