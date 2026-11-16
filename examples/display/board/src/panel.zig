//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The e-ink panel: an IT8951 controller on SPI_B channel 0, driven through
//! the firmware's ra8_epaper driver. The UI paints an 8-bit greyscale canvas
//! and this file sends the damaged part of it to the glass.

const ui = @import("ui");
const hal = @import("hal.zig");

pub const Error = error{PanelFailed};

pub const wiring = struct {
    pub const spi_channel: u8 = 0;
    pub const spi_baud_hz: u32 = 10_000_000;
    /// IT8951 /RESET on P4_00 and HRDY on P4_01, where the emulator's panel
    /// model drives them.
    pub const reset: hal.Pin = hal.pin(4, 0);
    pub const ready: hal.Pin = hal.pin(4, 1);
    pub const lut: [*:0]const u8 = "M641";
};

/// The window a panel's VCOM must sit in before the driver may refresh it.
pub const vcom = struct {
    pub const min_mv: u16 = 200;
    pub const max_mv: u16 = 4000;
};

pub const width: u16 = @intCast(ui.theme.panel.width);
pub const height: u16 = @intCast(ui.theme.panel.height);

var bus: hal.SpiBus = .{};

fn check(status: hal.Err) Error!void {
    if (status != hal.ok) return error.PanelFailed;
}

fn vcomGet(_: ?*anyopaque, out_mv: *u16) callconv(.c) hal.Err {
    return hal.ra8_epaper_get_vcom(out_mv);
}

fn vcomSet(_: ?*anyopaque, mv: u16) callconv(.c) hal.Err {
    return hal.ra8_epaper_set_vcom(mv);
}

/// The driver refuses every refresh until the panel's VCOM is resolved from
/// a trusted source and applied.
fn calibrate() Error!void {
    const cfg: hal.VcomCfg = .{
        .limits = .{ .min_mv = vcom.min_mv, .max_mv = vcom.max_mv },
        .panel = .{ .get = vcomGet, .set = vcomSet },
    };
    var result: hal.VcomResult = .{};
    try check(hal.ra8_epd_cal_resolve(&cfg, &result));
    try check(hal.ra8_epd_cal_apply(&cfg, &result));
}

/// Bring the SPI bus and the controller up. `pclka_hz` is the live PCLKA.
pub fn init(pclka_hz: u32) Error!void {
    const pins = hal.ra8_pin_interface_default();
    try check(pins.output_init(pins.ctx, wiring.reset, hal.level.high));
    try check(pins.input_init(pins.ctx, wiring.ready, hal.pull.up));
    try check(hal.ra8_spi_init(wiring.spi_channel, &.{ .baud_hz = wiring.spi_baud_hz, .pclka_hz = pclka_hz }));
    try check(hal.ra8_io_spi_bus_bind_spi_b(&bus, wiring.spi_channel));

    var cfg: hal.EpaperCfg = .{ .reset_pin = wiring.reset, .busy_pin = wiring.ready, .panel_width = width, .panel_height = height };
    try check(hal.ra8_io_spi_bus_as_ops(&bus, &cfg.bus));
    try check(hal.ra8_epaper_waveform_cfg_for_lut(wiring.lut, &cfg.waveform));
    try check(hal.ra8_epaper_init(&cfg));
    try calibrate();
}

/// Send the damaged part of `canvas` to the glass. The damaged rows are
/// loaded whole, in one command, because whole rows are contiguous in the
/// canvas; then only the damaged rectangle is refreshed: cleanly for a new
/// screen, fast otherwise.
pub fn flush(canvas: *const ui.Canvas, damage: ui.Damage) Error!void {
    const x: u16 = @intCast(@max(0, damage.rect.x));
    const y: u16 = @intCast(@max(0, damage.rect.y));
    const w: u16 = @intCast(@min(@as(i32, width) - x, damage.rect.w));
    const h: u16 = @intCast(@min(@as(i32, height) - y, damage.rect.h));
    if (w == 0 or h == 0) return;

    const rows: hal.Area = .{ .x = 0, .y = y, .width = width, .height = h };
    const first = @as(usize, y) * width;
    const bytes = @as(usize, h) * width;
    try check(hal.ra8_epaper_load_image(&rows, canvas.pixels[first..].ptr, bytes, hal.pixels.gray8, hal.pixels.big_endian));
    const area: hal.Area = .{ .x = x, .y = y, .width = w, .height = h };
    try check(hal.ra8_epaper_display_area(&area, if (damage.quality) hal.waveform.gc16 else hal.waveform.du));
}
