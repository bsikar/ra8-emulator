//! The board's two I2C lines: the RIIC controller with the two parts the
//! EK-RA8D2 puts on it, the PI4IOE5V6408 port expander (U15) and the camera's
//! SCCB side, and the I3C channel driven in legacy I2C mode with the carrier's
//! GT911 touch controller on it.
//!
//! The controller knows about transfers, not about parts. Which parts a board
//! populates is a board fact, so it lives here rather than in riic.zig.
const bus = @import("../periph/riic_bus.zig");
const gt911 = @import("../periph/i3c_gt911.zig");
const i3c = @import("../periph/i3c.zig");
const lsm6dso = @import("../periph/i3c_lsm6dso.zig");
const max17048 = @import("../periph/i3c_max17048.zig");
const ov5640 = @import("../periph/riic_ov5640.zig");
const periph = @import("../periph/registry.zig");
const pi4ioe = @import("../periph/riic_pi4ioe.zig");
const riic = @import("../periph/riic.zig");

pub const Wire = struct {
    controller: riic.Riic = riic.Riic.init(),
    expander: pi4ioe.Expander = .{},
    sensor: ov5640.Sensor = .{},
    /// The I3C channel in legacy I2C mode, and the three parts on it: the
    /// touch panel, the IMU and the fuel gauge that reports the battery.
    touchline: i3c.I3c = .{},
    panel: gt911.Panel = .{},
    imu: lsm6dso.Imu = .{},
    gauge: max17048.Gauge = .{},

    /// Put both lines and the board's parts on the bus. The blocks hold
    /// pointers into this struct, so this runs once the board has stopped
    /// moving.
    pub fn attach(self: *Wire, window: *periph.Bus) !void {
        try window.add(self.block());
        try window.add(self.touchBlock());
        try self.controller.attachDevice(self.expander.device());
        try self.controller.attachDevice(self.sensor.device());
        try self.touchline.attachDevice(self.panel.device());
        try self.touchline.attachDevice(self.imu.device());
        try self.touchline.attachDevice(self.gauge.device());
    }

    pub fn block(self: *Wire) periph.Block {
        return self.controller.block();
    }

    pub fn touchBlock(self: *Wire) periph.Block {
        return self.touchline.block();
    }

    pub fn quiet(self: *const Wire) bool {
        return self.controller.quiet() and self.expander.quiet() and self.sensor.quiet() and
            self.touchline.quiet() and self.panel.quiet() and self.imu.quiet() and
            self.gauge.quiet();
    }
};
