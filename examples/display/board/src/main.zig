//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The UI firmware image. Brings the board, the SDRAM that holds the canvas
//! and the e-ink panel up, then runs the same UI the host goldens render:
//! poll input, hand it to the app, flush what it damaged.

const ui = @import("ui");
const hal = @import("hal.zig");
const panel = @import("panel.zig");
const input = @import("input.zig");

// The box layout and rect helpers ra8_widget calls, compiled into this image
// from the firmware's own sources.
comptime {
    _ = @import("ra8_box");
    _ = @import("ra8_ui_rect");
}

pub const console_baud: u32 = 115_200;
pub const poll_ms: u32 = 20;
pub const settle_ms: u32 = 50;

const pixel_count = @as(usize, panel.width) * panel.height;

/// The canvas the widgets paint and the copy of what the glass shows.
/// Together they are 3 MB, so they live in external SDRAM.
var canvas_pixels: [pixel_count]u8 linksection(".sdram_data") = undefined;
var shown_pixels: [pixel_count]u8 linksection(".sdram_data") = undefined;

var canvas: ui.Canvas = .{ .width = panel.width, .height = panel.height, .pixels = &canvas_pixels };
var fakes: ui.Fakes = .{};
var app: ui.App = undefined;

fn say(line: []const u8) void {
    _ = hal.ra8_board_uart_console_write(line.ptr, line.len);
    _ = hal.ra8_board_uart_console_flush();
}

fn park(reason: []const u8) noreturn {
    say(reason);
    while (true) asm volatile ("wfi");
}

/// One console line per screen shown, so a run can be followed by name.
fn announce() void {
    say("ui: ");
    say(@tagName(app.state.stack.top()));
    say("\r\n");
}

fn show(damage: ui.Damage) void {
    panel.flush(&canvas, damage) catch park("ui: FAIL panel flush\r\n");
    if (damage.quality) announce();
}

fn handle(event: input.Event) void {
    const damage = switch (event) {
        .tap => |spot| app.tap(spot.x, spot.y),
        .power => app.press(.power),
    } catch park("ui: FAIL compose\r\n");
    if (damage) |changed| show(changed);
}

export fn main() callconv(.c) c_int {
    var clocks: hal.BringupOut = .{};
    if (hal.ra8_board_bringup(&.{ .console_baud = console_baud, .leds_mask = 0, .enable_interrupts = true }, &clocks) != hal.ok) {
        while (true) asm volatile ("wfi");
    }
    hal.ra8_delay_ms(settle_ms);
    if (hal.ra8_sdramc_init() != hal.ok) park("ui: FAIL sdram\r\n");
    panel.init(clocks.pclka_hz) catch park("ui: FAIL panel init\r\n");
    input.init();

    @memset(&shown_pixels, 0xFF);
    app.init(&canvas, &shown_pixels, fakes.services());
    show(app.draw() catch park("ui: FAIL first draw\r\n"));
    say("ui: ready\r\n");

    while (true) {
        if (input.poll()) |event| handle(event);
        hal.ra8_delay_ms(poll_ms);
    }
}
