//! The graphics story of a run: the power domain the blocks live in, the
//! panel the display controller is scanning, and what the drawing engine put
//! in the framebuffer. Split out of report.zig, which was at the file-length
//! limit, and they belong together anyway: all three read the same domain.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// The three in the order a person reads them: what is powered, what the
/// panel shows, what drew it.
pub fn sections(board: *Board, out: Writer) !void {
    try domain(board, out);
    try display(board, out);
    try raster(board, out);
}

/// What the panel is being scanned from, and the loud case behind it: the
/// graphics power domain is gated off at reset, so a display controller
/// programmed before PDCTRGD is cleared reaches no register at all. dev
/// shadows those writes whatever the domain is doing, so the descriptor
/// looks right there and the panel is dark on the bench.
pub fn display(board: *Board, out: Writer) !void {
    const unit = &board.display;
    if (unit.quiet()) return;
    if (unit.framebuffer()) |frame| {
        try out.print(
            "GLCDC: GR{d} scanning 0x{X:0>8}, {d}x{d}, stride {d}, {s}, output stage {s}\n",
            .{
                frame.layer,
                frame.base,
                frame.width,
                frame.height,
                frame.stride,
                @tagName(frame.format),
                if (frame.enabled) "on" else "OFF (BG_EN.EN clear, panel blank)",
            },
        );
    } else {
        try out.print("GLCDC: {d} write(s), no layer fetching a framebuffer\n", .{unit.writes});
    }
    if (unit.dropped_unpowered == 0 and unit.dark_reads == 0) return;
    try out.print(
        "GLCDC: DROPPED {d} write(s) and {d} read(s) with the graphics domain gated off (clear PDCTRGD.PDDE first)\n",
        .{ unit.dropped_unpowered, unit.dark_reads },
    );
}

/// What the drawing engine actually put in the framebuffer. The loud case is
/// a declined render: the configuration was one this model will not invent
/// pixels for, so the app goes visibly blank here instead of passing on
/// pixels the bench would not have produced.
pub fn raster(board: *Board, out: Writer) !void {
    const unit = &board.raster;
    if (unit.quiet()) return;
    try out.print(
        "DRW: {d} box(es) rasterized, last {d}x{d}, {d} pixel(s)\n",
        .{ unit.renders, unit.last_width, unit.last_height, unit.pixels },
    );
    if (unit.dlists != 0) {
        try out.print(
            "DRW: {d} display list(s), {d} stopped on an unmodelled entry\n",
            .{ unit.dlists, unit.dlist_stops },
        );
    }
    if (unit.declined != 0) {
        try out.print(
            "DRW: DECLINED {d} render(s), last because of {s} (unmodelled: nothing drawn)\n",
            .{ unit.declined, @tagName(unit.last_decline.?) },
        );
    }
    if (unit.faults != 0) {
        try out.print("DRW: {d} pixel access(es) went nowhere mapped\n", .{unit.faults});
    }
    if (unit.dropped_unpowered == 0 and unit.dark_reads == 0) return;
    try out.print(
        "DRW: DROPPED {d} write(s) and {d} read(s) with the graphics domain gated off (clear PDCTRGD.PDDE first)\n",
        .{ unit.dropped_unpowered, unit.dark_reads },
    );
}

/// PDCTRGD itself, once the firmware has been near it. A write dropped by
/// the PRC1 lock is the silent failure: no fault, no flag, domain still dark.
pub fn domain(board: *Board, out: Writer) !void {
    const unit = &board.graphics;
    if (unit.quiet()) return;
    try out.print(
        "PWR-GRAPHICS: domain {s}, {d} power-on(s), {d} power-off(s)\n",
        .{ if (unit.powered()) "powered" else "GATED", unit.power_ons, unit.power_offs },
    );
    if (unit.dropped_locked == 0) return;
    try out.print(
        "PWR-GRAPHICS: DROPPED {d} write(s) with PRCR.PRC1 locked (unlock with 0xA502)\n",
        .{unit.dropped_locked},
    );
}
