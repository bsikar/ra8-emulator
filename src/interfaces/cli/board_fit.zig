//! The board a run asks for on its command line, fitted before anything
//! loads: its part, its card, its panel contacts, its cell and the stick in
//! its USB jack (RA8EMU-592: out of main so the engine and Zig paths share
//! it). Each piece refuses on its own terms and says so; this only puts them
//! in order.
const std = @import("std");
const cli = @import("cli.zig");
const Board = @import("../../board/board.zig").Board;
const usb_plug = @import("../../board/usb_plug.zig");
const pacing = @import("../../periph/time/pacing.zig");

pub fn fit(board: *Board, allocator: std.mem.Allocator, options: cli.Options) !void {
    board.part = options.part;
    board.memory_monitors = .{ .cms = options.cms, .sfs = options.sfs };
    board.wire.click = options.click;
    // A run's RTC counts virtual time (RA8EMU-185): with idle fast-forward a
    // sleeping core reaches the next second edge, so the geared clock the
    // corpus was first recorded on is only kept for the RTC's own tests.
    board.clock.pace.mode = .virtual;
    if (options.rtc_start) |at| board.clock.seed(at);
    if (options.speed) |factor| try pacing.attachHost(&board.time, factor);
    board.asks.keep(allocator, options.attaches[0..options.attach_count]);
    if (options.usb_loop) board.usb.loopBack();
    board.capture.source = try options.camera.open(allocator, &board.wire.sensor.format);
    try cli.card_setup.prepare(board, options.trace_sd, options.sd_path, options.sd_size_mb, options.sd_new, options.sd_label);
    try cli.card_setup.prepareSdhi(board, options.sdhi);
    queueTouches(board, options);
    if (options.touch_in) |path| try board.touch_input.open(path);
    try setBattery(board, options);
    try usb_plug.apply(&board.usb, allocator, options.usb_disk);
    try cli.usbip_export.run.install(&board.usb, allocator, options.usbip);
}

/// Put the contacts the command line asked for on the touch panel. The queue
/// is the same depth as the flag allows, so nothing here can overflow it.
fn queueTouches(board: *Board, options: cli.Options) void {
    for (options.touches[0..options.touch_count]) |contact| {
        board.wire.panel.queue(contact) catch return;
    }
}

/// Tell the fuel gauge what is in the battery. A state-of-charge over full
/// is refused here rather than clamped into a number nothing measured.
fn setBattery(board: *Board, options: cli.Options) !void {
    board.wire.gauge.setBattery(options.battery) catch |err| {
        std.debug.print("--battery {d}: not a state-of-charge a cell can hold\n", .{options.battery.soc_pct});
        return err;
    };
}
