//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The firmware's board and HAL C layers, as the UI image reaches them:
//! extern declarations and the handful of C structs they pass, each
//! mirrored from the header named beside it. Nothing here has behaviour.

/// `ra8_err_t` (ra8_err.h): zero is success.
pub const Err = u16;
pub const ok: Err = 0;

/// `ra8_port_pin_t` (ra8_port_constants.h): `(port << 8) | pin`.
pub const Pin = u16;

pub fn pin(port: u8, number: u8) Pin {
    return (@as(Pin, port) << 8) | number;
}

pub const level = struct {
    pub const low: u8 = 0;
    pub const high: u8 = 1;
};

pub const pull = struct {
    pub const none: u8 = 0;
    pub const up: u8 = 1;
};

/// `ra8_board_bringup_cfg_t` (ra8_board_ek_ra8d2_bringup.h).
pub const BringupCfg = extern struct {
    console_baud: u32,
    leds_mask: u32,
    enable_interrupts: bool,
};

/// `ra8_board_bringup_out_t`.
pub const BringupOut = extern struct {
    cpuclk0_hz: u32 = 0,
    pclka_hz: u32 = 0,
};

/// `ra8_pin_interface_t` (ra8_pin_interface.h).
pub const PinInterface = extern struct {
    output_init: *const fn (ctx: ?*anyopaque, which: Pin, init_level: u8) callconv(.c) Err,
    input_init: *const fn (ctx: ?*anyopaque, which: Pin, pull_mode: u8) callconv(.c) Err,
    write: *const fn (ctx: ?*anyopaque, which: Pin, value: u8) callconv(.c) Err,
    read: *const fn (ctx: ?*anyopaque, which: Pin, out_level: *u8) callconv(.c) Err,
    toggle: *const fn (ctx: ?*anyopaque, which: Pin) callconv(.c) Err,
    release: *const fn (ctx: ?*anyopaque, which: Pin) callconv(.c) Err,
    ctx: ?*anyopaque,
};

/// `ra8_spi_cfg_t` (ra8_spi.h). Mode 0 is CPOL=0, CPHA=0.
pub const SpiCfg = extern struct {
    baud_hz: u32,
    pclka_hz: u32,
    mode: u8 = 0,
    lsb_first: bool = false,
    loopback: bool = false,
};

/// `ra8_io_spi_bus_t` (ra8_io_spi_bus.h).
pub const SpiBus = extern struct {
    iface: ?*const anyopaque = null,
    ctx: ?*anyopaque = null,
};

/// `ra8_spi_bus_ops_t` (ra8_spi_bus_ops.h).
pub const SpiBusOps = extern struct {
    xfer8: ?*const fn (ctx: ?*anyopaque, tx: u8, rx: ?*u8) callconv(.c) Err = null,
    ctx: ?*anyopaque = null,
};

/// `ra8_epaper_waveform_cfg_t` (ra8_epaper.h).
pub const WaveformCfg = extern struct {
    init: u8 = 0,
    du: u8 = 0,
    gc16: u8 = 0,
    a2: u8 = 0,
};

/// `ra8_epaper_cfg_t`.
pub const EpaperCfg = extern struct {
    bus: SpiBusOps = .{},
    waveform: WaveformCfg = .{},
    reset_pin: Pin,
    busy_pin: Pin,
    panel_width: u16,
    panel_height: u16,
};

/// `ra8_epaper_area_t`.
pub const Area = extern struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

/// `ra8_epaper_waveform_t`.
pub const waveform = struct {
    pub const du: u8 = 1;
    pub const gc16: u8 = 2;
};

/// `ra8_epaper_pixel_format_t` and `ra8_epaper_endian_t`. The driver clocks
/// a buffer out in memory order and the controller assembles 16-bit words
/// most significant byte first, so a byte-per-pixel buffer is big-endian:
/// the first pixel of each pair is the word's high byte.
pub const pixels = struct {
    pub const gray8: u8 = 3;
    pub const big_endian: u8 = 1;
};

/// `ra8_epd_cal_cfg_t` (ra8_epd_cal.h) and the structs inside it.
pub const VcomLimits = extern struct { min_mv: u16, max_mv: u16 };
pub const VcomPanel = extern struct {
    get: ?*const fn (ctx: ?*anyopaque, out_mv: *u16) callconv(.c) Err,
    set: ?*const fn (ctx: ?*anyopaque, mv: u16) callconv(.c) Err,
    ctx: ?*anyopaque = null,
};
pub const VcomStore = extern struct {
    read: ?*const anyopaque = null,
    write: ?*const anyopaque = null,
    ctx: ?*anyopaque = null,
};
pub const VcomCfg = extern struct {
    limits: VcomLimits,
    panel: VcomPanel,
    store: VcomStore = .{},
    provisioned_mv: u16 = 0,
    has_provisioned: bool = false,
};
pub const VcomResult = extern struct { vcom_mv: u16 = 0, source: u8 = 0 };

/// `ra8_board_touch_cfg_t` (ra8_board_ek_ra8d2_touch.h). 32 is "no IRQ pin".
pub const TouchCfg = extern struct { max_points: u8 = 1, irq_pin: u8 = 32 };

/// `ra8_touch_point_t` (ra8_touch.h).
pub const TouchPoint = extern struct { x: u16 = 0, y: u16 = 0, track_id: u8 = 0, pressure: u8 = 0 };

/// `ra8_board_sw_id_t` and `ra8_board_sw_state_t` (connectors header).
pub const switches = struct {
    pub const sw1: u8 = 0;
    pub const pressed: u8 = 1;
};

pub extern fn ra8_board_bringup(cfg: *const BringupCfg, out: *BringupOut) Err;
pub extern fn ra8_board_uart_console_write(data: [*]const u8, len: usize) Err;
pub extern fn ra8_board_uart_console_flush() Err;
pub extern fn ra8_delay_ms(ms: u32) void;
pub extern fn ra8_time_ms() u32;
pub extern fn ra8_sdramc_init() Err;
pub extern fn ra8_pin_interface_default() *const PinInterface;
pub extern fn ra8_spi_init(channel: u8, cfg: *const SpiCfg) Err;
pub extern fn ra8_io_spi_bus_bind_spi_b(bus: *SpiBus, channel: u8) Err;
pub extern fn ra8_io_spi_bus_as_ops(bus: *const SpiBus, out: *SpiBusOps) Err;
pub extern fn ra8_epaper_waveform_cfg_for_lut(lut_version: [*:0]const u8, out: *WaveformCfg) Err;
pub extern fn ra8_epaper_init(cfg: *const EpaperCfg) Err;
pub extern fn ra8_epaper_get_vcom(out_mv: *u16) Err;
pub extern fn ra8_epaper_set_vcom(mv: u16) Err;
pub extern fn ra8_epaper_load_image(area: *const Area, buf: [*]const u8, buf_len: usize, format: u8, endian: u8) Err;
pub extern fn ra8_epaper_display_area(area: *const Area, mode: u8) Err;
pub extern fn ra8_epd_cal_resolve(cfg: *const VcomCfg, out: *VcomResult) Err;
pub extern fn ra8_epd_cal_apply(cfg: *const VcomCfg, result: *const VcomResult) Err;
pub extern fn ra8_board_touch_open(cfg: *const TouchCfg) Err;
pub extern fn ra8_touch_read(out_points: *TouchPoint, max_count: u8, got_count: *u8) Err;
pub extern fn ra8_board_sw_init(which: u8) Err;
pub extern fn ra8_board_sw_read(which: u8, out_state: *u8) Err;
