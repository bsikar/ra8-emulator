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
    try panel(board, out);
}

/// The other display path: the e-paper panel on the SPI line. A command
/// sent to a sleeping panel, a stream longer than the rectangle it declared,
/// a drain past the end of the device-info block, a write to a register the
/// controller owns, and a data word with no command behind it are all things
/// dev let pass, so each is reported apart from the pixels that landed.
pub fn panel(board: *Board, out: Writer) !void {
    const unit = &board.panel;
    if (unit.quiet()) return;
    try out.print(
        "IT8951 e-ink: {d} command(s), {d} pixel(s) loaded, {d} refresh(es), last waveform 0x{X}, VCOM {d}mV, {s}\n",
        .{
            unit.commands,
            unit.pixels,
            unit.refreshes,
            unit.last_waveform,
            unit.vcom_mv,
            if (unit.awake) "awake" else "ASLEEP",
        },
    );
    if (unit.asleep != 0) {
        try out.print(
            "IT8951 e-ink: REFUSED {d} command(s) with the panel asleep (wake it with SYS_RUN first)\n",
            .{unit.asleep},
        );
    }
    if (unit.overrun != 0) {
        try out.print(
            "IT8951 e-ink: REFUSED {d} pixel word(s) past the {d}x{d} rectangle the load declared\n",
            .{ unit.overrun, unit.load_width, unit.load_height },
        );
    }
    if (unit.overdrain != 0 or unit.stray != 0 or unit.read_only != 0 or unit.spilled != 0) {
        try out.print(
            "IT8951 e-ink: {d} read(s) past the device-info block, {d} data word(s) with no command, {d} write(s) to LUTAFSR, {d} register write(s) dropped\n",
            .{ unit.overdrain, unit.stray, unit.read_only, unit.spilled },
        );
    }
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
    if (unit.limited != 0) {
        try out.print(
            "DRW: {d} render(s) shaped by the spatial limiters, {d} pixel(s) clipped out, {d} on a boundary this model paints hard\n",
            .{ unit.limited, unit.clipped, unit.hard_edges },
        );
    }
    try texture(unit, out);
    try caches(unit, out);
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

/// The framebuffer cache, which dev declines rather than models: the HAL
/// enables it ahead of every stroked line and every triangle, so on dev
/// every one of those came back to a blank framebuffer and passed. Here the
/// render happens and the pixels sit in the cache until a CFLUSHFX, which
/// is worth saying out loud when a run ends with some still held.
fn caches(unit: anytype, out: Writer) !void {
    const fb = &unit.pixel_cache;
    if (fb.quiet()) return;
    try out.print(
        "DRW: framebuffer cache held {d} pixel write(s), wrote back {d} over {d} flush(es), {d} evicted to make room, {d} destination read(s) served from it\n",
        .{ fb.held, fb.written_back, fb.flushes, fb.evicted, fb.forwarded },
    );
    if (fb.dirty()) {
        try out.print(
            "DRW: {d} pixel(s) are STILL IN THE CACHE and not in memory (no CFLUSHFX since they were painted)\n",
            .{fb.used},
        );
    }
    if (fb.disabled_dirty != 0) {
        try out.print(
            "DRW: the framebuffer cache was switched off {d} time(s) with pixels still held (silicon leaves that undefined; written back here)\n",
            .{fb.disabled_dirty},
        );
    }
    if (fb.faults != 0) {
        try out.print("DRW: {d} cache write-back(s) went nowhere mapped\n", .{fb.faults});
    }
}

/// The texture source behind a blit, which dev models not at all: it
/// accepts the texture registers and discards them, then declines every
/// render with a source enabled, so every image, glyph and icon came back
/// to a blank framebuffer and the app passed.
fn texture(unit: *const @TypeOf(@as(Board, undefined).raster), out: Writer) !void {
    const source = &unit.texture;
    if (source.quiet()) return;
    try out.print(
        "DRW: {d} texel(s) sampled, {d} colour-keyed out, {d} coordinate(s) folded back into the texture\n",
        .{ source.texels, source.keyed, source.wrapped },
    );
    if (source.off_ram == 0 and source.faults == 0) return;
    try out.print(
        "DRW: REFUSED {d} texel read(s) aimed outside RAM, {d} that went nowhere mapped\n",
        .{ source.off_ram, source.faults },
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
