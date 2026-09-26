//! The GLCDC system control block in the report: whether the pixel clock
//! ever started, and what the status word a driver polls actually says.
//! Split out of report_graphics.zig, which was at the file-length limit.
const Writer = @import("report.zig").Writer;

/// The system control block: whether the pixel clock ever started, and what
/// the status word a driver polls actually says. dev snoops none of this, so
/// STMON there reads back the last word written to it and a panel with its
/// clock still gated is reported as a picture.
pub fn sections(unit: anytype, out: Writer) !void {
    const sys = &unit.system;
    if (sys.quiet()) return;
    if (!sys.clocked()) {
        try out.print(
            "GLCDC clock: PANEL_CLK.CLKEN clear, {d} frame(s) refused (the panel is never scanned)\n",
            .{sys.unclocked},
        );
    } else {
        try out.print("GLCDC clock: {s} / {d}, {d} frame(s) scanned\n", .{
            sys.source().name(),
            sys.divider(),
            sys.frames,
        });
    }
    try status(sys, out);
}

/// What firmware waiting on a frame would find, and the three ways that
/// wait goes wrong: a frame nothing was armed to detect, a state cleared
/// that was never up, and a layer that could not keep up with the scan.
fn status(sys: anytype, out: Writer) !void {
    try out.print(
        "GLCDC status: STMON 0x{X:0>2}, armed 0x{X:0>2}, enabled 0x{X:0>2}, {d} detection(s), {d} would pend\n",
        .{ sys.status, sys.detect, sys.interrupts, sys.detections, sys.interrupts_due },
    );
    if (sys.undetected != 0) {
        try out.print(
            "GLCDC status: {d} frame(s) landed with VPOS detection disarmed (DTCTEN.VPOSDTC clear, nothing to wait on)\n",
            .{sys.undetected},
        );
    }
    if (sys.underflows != 0) {
        try out.print("GLCDC status: {d} layer underflow(s)\n", .{sys.underflows});
    }
    if (sys.stale_clears != 0) {
        try out.print(
            "GLCDC status: {d} STCLR bit(s) cleared a state that was never up\n",
            .{sys.stale_clears},
        );
    }
    if (sys.status_writes != 0) {
        try out.print(
            "GLCDC status: {d} write(s) to STMON, which is read-only (clear through STCLR)\n",
            .{sys.status_writes},
        );
    }
}
