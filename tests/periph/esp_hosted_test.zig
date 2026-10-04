//! The ESP32-C6 link response and its chip-select sideband.
const std = @import("std");
const ra8 = @import("ra8");
const c6 = ra8.periph.esp_hosted;
const gpio = ra8.periph.gpio;
const sci = ra8.periph.sci;
const sci_spi = ra8.periph.sci_spi;

test "an empty C6 transmit queue answers with esp-hosted idle filler" {
    var serial = sci.Sci.init();
    var pins = gpio.Gpio.init();
    var peer = c6.C6{};
    peer.init(&serial, &pins);
    const line = peer.device();
    var response: []const u8 = &.{};
    for (0..c6.frame_size) |i| {
        response = line.feed(0);
        if (i == 0) {
            try std.testing.expectEqual(c6.idle_header, response[0]);
        } else {
            try std.testing.expectEqual(@as(u8, 0), response[0]);
        }
    }
    response = line.feed(0);
    try std.testing.expectEqual(c6.idle_header, response[0]);
}

test "HANDSHAKE follows Pmod1 chip select while DATA_READY idles low" {
    var serial = sci.Sci.init();
    var pins = gpio.Gpio.init();
    var peer = c6.C6{};
    peer.init(&serial, &pins);
    try std.testing.expect(pins.pinLevel(c6.handshake_port, c6.handshake_pin));
    try std.testing.expect(!pins.pinLevel(c6.data_ready_port, c6.data_ready_pin));

    const pdr: u32 = @as(u32, 1) << c6.chip_select_pin;
    const high = (pdr << 16) | pdr;
    pins.applyWrite(gpio.regAddress(c6.chip_select_port, gpio.pcntr1), 4, high);
    try std.testing.expect(pins.pinLevel(c6.handshake_port, c6.handshake_pin));

    pins.applyWrite(gpio.regAddress(c6.chip_select_port, gpio.pcntr1), 4, pdr);
    try std.testing.expect(!pins.pinLevel(c6.handshake_port, c6.handshake_pin));
}

test "SCI2 receives the C6 idle header in Simple-SPI mode" {
    var serial = sci.Sci.init();
    var pins = gpio.Gpio.init();
    var peer = c6.C6{};
    peer.init(&serial, &pins);
    serial.write(
        sci.regAddress(c6.channel, sci.off_ccr3),
        4,
        sci_spi.mod.simple_spi << sci_spi.mod.shift,
    );
    serial.write(
        sci.regAddress(c6.channel, sci.off_ccr0),
        4,
        sci.ccr0.te | sci.ccr0.re,
    );
    serial.write(sci.regAddress(c6.channel, sci.off_tdr), 4, 0);
    try std.testing.expectEqual(
        @as(u32, c6.idle_header),
        serial.read(sci.regAddress(c6.channel, sci.off_rdr), 4),
    );
}

test {
    _ = @import("esp_hosted/esp_frame_test.zig");
}
