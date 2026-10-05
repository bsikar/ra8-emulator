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
pub const event = @import("esp_hosted/esp_event.zig");
pub const link = @import("esp_hosted/esp_link.zig");
pub const rpc = @import("esp_hosted/esp_rpc.zig");
pub const station = @import("esp_hosted/esp_station.zig");
pub const queue = @import("esp_hosted/esp_queue.zig");
pub const eth = @import("esp_hosted/esp_eth.zig");
pub const dhcp = @import("esp_hosted/esp_dhcp.zig");
pub const gateway = @import("esp_hosted/esp_gateway.zig");
pub const scan = @import("esp_hosted/esp_scan.zig");

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
    reply: [1]u8 = .{0},
    pins: ?*gpio.Gpio = null,
    wire: link.Link = .{},

    pub fn init(self: *C6, serial: *sci.Sci, pins: *gpio.Gpio) void {
        self.connect(pins);
        serial.attachDevice(channel, self.device());
    }

    pub fn connect(self: *C6, pins: *gpio.Gpio) void {
        self.pins = pins;
        pins.observe(self, pinChanged);
        pins.setInput(handshake_port, handshake_pin, true);
        pins.setInput(data_ready_port, data_ready_pin, false);
        pins.setInput(4, 12, true);
        pins.setInput(4, 13, true);
    }

    pub fn device(self: *C6) sci.Device {
        return .{ .context = self, .feedFn = feed, .spi_only = true, .connectFn = connectDevice, .tickFn = tickDevice };
    }

    fn connectDevice(context: *anyopaque, pins: *gpio.Gpio) void {
        const self: *C6 = @ptrCast(@alignCast(context));
        self.connect(pins);
    }

    fn tickDevice(context: *anyopaque, pins: *gpio.Gpio) void {
        const self: *C6 = @ptrCast(@alignCast(context));
        self.tick(pins);
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
        const self: *C6 = @ptrCast(@alignCast(context));
        self.reply[0] = self.wire.exchange(byte);
        if (self.pins) |pins| {
            pins.setInput(handshake_port, handshake_pin, false);
            pins.setInput(data_ready_port, data_ready_pin, self.wire.dataReady());
        }
        return &self.reply;
    }
};
