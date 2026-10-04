//! The pin models a run can attach: a push button and an LED.
const gpio_pins = @import("gpio_pins.zig");

/// A push button to ground with a pull-up: released reads high, pressed
/// reads low, the same as SW1 and SW2 on the board.
pub const Button = struct {
    link: ?gpio_pins.Link = null,
    pressed: bool = false,

    pub fn press(self: *Button) void {
        self.pressed = true;
        self.drive();
    }

    pub fn release(self: *Button) void {
        self.pressed = false;
        self.drive();
    }

    fn drive(self: *Button) void {
        if (self.link) |link| link.drive(!self.pressed);
    }

    pub fn device(self: *Button) gpio_pins.Device {
        return .{ .context = self, .connectFn = connect, .heardFn = ignore };
    }

    fn connect(context: *anyopaque, link: gpio_pins.Link) void {
        const self: *Button = @ptrCast(@alignCast(context));
        self.link = link;
        self.drive();
    }

    fn ignore(_: *anyopaque, _: bool) void {}
};

/// An LED on a pin the firmware drives: whether it is lit, and how many
/// times that changed.
pub const Led = struct {
    lit: bool = false,
    edges: u32 = 0,

    pub fn device(self: *Led) gpio_pins.Device {
        return .{ .context = self, .connectFn = connect, .heardFn = heard };
    }

    fn connect(context: *anyopaque, link: gpio_pins.Link) void {
        const self: *Led = @ptrCast(@alignCast(context));
        self.lit = link.level();
    }

    fn heard(context: *anyopaque, high: bool) void {
        const self: *Led = @ptrCast(@alignCast(context));
        if (self.lit == high) return;
        self.lit = high;
        self.edges += 1;
    }
};
