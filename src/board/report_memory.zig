//! The memory-controller part of the end-of-run report.
//!
//! On-chip SRAM is host memory here, so the only window onto the ECC path is
//! what the decoder self-test latched in SRAMESR and what it left in
//! SRAMEAR.
const std = @import("std");

const Board = @import("board.zig").Board;

const Writer = std.fs.File.Writer;

/// Quiet unless the run touched the ECC path. The refused store is the loud
/// case: SRAMESR is what the decoder found, so an image that wrote it was
/// claiming a caught fault it never injected.
pub fn sections(board: *Board, out: Writer) !void {
    const memory = &board.ecc;
    if (memory.quiet()) return;
    try out.print(
        "SRAM-ECC: {d} self-test latch(es), SRAMESR 0x{X:0>4}\n",
        .{ memory.latches, memory.esr },
    );
    if (memory.faked != 0) {
        try out.print(
            "SRAM-ECC: REFUSED {d} store(s) to SRAMESR, firmware cannot raise an ECC error flag itself\n",
            .{memory.faked},
        );
    }
    try protection(&memory.lock, out);
}

/// SRAMPRCR. Quiet unless a key was written or a guarded store happened,
/// and loud when one was turned away: a configuration write that never
/// landed is the kind of thing a driver does not notice until the bench.
fn protection(lock: *const @import("../periph/sram_lock.zig").Lock, out: Writer) !void {
    if (lock.quiet()) return;
    try out.print(
        "SRAMPRCR: {s}, {d} key write(s), {d} guarded store(s) through\n",
        .{ if (lock.open()) "unlocked" else "locked", lock.accepted, lock.allowed },
    );
    if (lock.ignored != 0) {
        try out.print(
            "SRAMPRCR: {d} key write(s) IGNORED, the KW field was not 0xA5\n",
            .{lock.ignored},
        );
    }
    if (lock.blocked != 0) {
        try out.print(
            "SRAMPRCR: REFUSED {d} store(s) to a guarded register with the controller locked\n",
            .{lock.blocked},
        );
    }
}
