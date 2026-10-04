//! The EK-RA8D2's SPI peer: the idle frame and sideband lines of esp-hosted.
//!
//! Pmod1 connects SCI2 Simple-SPI to the ESP32-C6. The ESP32-C6 peripheral
//! firmware emits 1600-byte full-duplex frames. Its empty-queue filler starts
//! with if_type=ESP_MAX_IF and if_num=15; the probe accepts that frame as
//! proof that the link is alive. HANDSHAKE is on P006 and follows chip select
//! P804. DATA_READY is on P402 and stays low with an empty transmit queue.
const sci = @import("sci/sci.zig");
const gpio = @import("gpio/gpio.zig");

/// The esp-hosted frame codec (RA8EMU-597).
pub const frame = @import("esp_hosted/esp_frame.zig");

pub const channel: usize = 2;
pub const handshake_port: u8 = 0;
pub const handshake_pin: u4 = 6;
pub const data_ready_port: u8 = 4;
pub const data_ready_pin: u4 = 2;
pub const chip_select_port: u8 = 8;
pub const chip_select_pin: u4 = 4;
pub const frame_size: u16 = 1600;
pub const idle_header: u8 = 0xF8;

/// The ESP32-C6 endpoint used by SCI2 and the Pmod1 sideband pins.
pub const C6 = struct {
    frame_offset: u16 = 0,
    reply: [1]u8 = .{0},
    pins: ?*gpio.Gpio = null,

    pub fn init(self: *C6, serial: *sci.Sci, pins: *gpio.Gpio) void {
        serial.attachDevice(channel, self.device());
        self.pins = pins;
        pins.observe(self, pinChanged);
        pins.setInput(handshake_port, handshake_pin, true);
        pins.setInput(data_ready_port, data_ready_pin, false);
        pins.setInput(4, 12, true);
        pins.setInput(4, 13, true);
    }

    pub fn device(self: *C6) sci.Device {
        return .{ .context = self, .feedFn = feed, .spi_only = true };
    }

    /// Track the external chip-select level and drive HANDSHAKE from it.
    pub fn tick(self: *C6, pins: *gpio.Gpio) void {
        _ = self;
        const direction = pins.readReg(
            gpio.regAddress(chip_select_port, gpio.pcntr1),
            4,
        );
        const selected = direction & (@as(u32, 1) << chip_select_pin) != 0;
        const handshake = !selected or pins.pinLevel(chip_select_port, chip_select_pin);
        pins.setInput(handshake_port, handshake_pin, handshake);
    }

    fn pinChanged(context: *anyopaque, pins: *gpio.Gpio, port: u8) void {
        if (port != chip_select_port) return;
        const self: *C6 = @ptrCast(@alignCast(context));
        self.tick(pins);
    }

    fn feed(context: *anyopaque, byte: u8) []const u8 {
        _ = byte;
        const self: *C6 = @ptrCast(@alignCast(context));
        if (self.pins) |pins| pins.setInput(handshake_port, handshake_pin, false);
        self.reply[0] = if (self.frame_offset == 0) idle_header else 0;
        self.frame_offset += 1;
        if (self.frame_offset == frame_size) self.frame_offset = 0;
        return &self.reply;
    }
};
