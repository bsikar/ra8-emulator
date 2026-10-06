//! The EK-RA8D2's SPI peer: the idle frame and sideband lines of esp-hosted.
const sci = @import("sci/sci.zig");
const gpio = @import("gpio/gpio.zig");

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
pub const dns = @import("esp_hosted/esp_dns.zig");
pub const net = @import("esp_hosted/esp_net.zig");

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

    pub fn deinit(self: *C6) void {
        self.wire.deinit();
    }
    pub fn quiet(self: *const C6) bool {
        return !self.wire.networkActive();
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

    /// Polls host network traffic and refreshes the C6 sideband pins.
    pub fn tick(self: *C6, pins: *gpio.Gpio) void {
        self.wire.poll();
        self.updatePins(pins);
    }

    fn updatePins(self: *C6, pins: *gpio.Gpio) void {
        const direction = pins.readReg(gpio.regAddress(chip_select_port, gpio.pcntr1), 4);
        const selected = direction & (@as(u32, 1) << chip_select_pin) != 0;
        const handshake = !selected or pins.pinLevel(chip_select_port, chip_select_pin);
        pins.setInput(handshake_port, handshake_pin, handshake);
        pins.setInput(data_ready_port, data_ready_pin, self.wire.dataReady());
    }

    fn pinChanged(context: *anyopaque, pins: *gpio.Gpio, port: u8) void {
        if (port != chip_select_port) return;
        const self: *C6 = @ptrCast(@alignCast(context));
        self.updatePins(pins);
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
