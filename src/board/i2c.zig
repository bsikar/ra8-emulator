//! The board's system I2C bus: the RIIC controller and the two parts the
//! EK-RA8D2 puts on it, the PI4IOE5V6408 port expander (U15) and the camera's
//! SCCB side.
//!
//! The controller knows about transfers, not about parts. Which parts a board
//! populates is a board fact, so it lives here rather than in riic.zig.
const bus = @import("../periph/riic_bus.zig");
const ov5640 = @import("../periph/riic_ov5640.zig");
const periph = @import("../periph/registry.zig");
const pi4ioe = @import("../periph/riic_pi4ioe.zig");
const riic = @import("../periph/riic.zig");

pub const Wire = struct {
    controller: riic.Riic = riic.Riic.init(),
    expander: pi4ioe.Expander = .{},
    sensor: ov5640.Sensor = .{},

    /// Put the board's parts on the bus. The controller holds pointers into
    /// this struct, so this runs once the board has stopped moving.
    pub fn attach(self: *Wire) bus.Error!void {
        try self.controller.attachDevice(self.expander.device());
        try self.controller.attachDevice(self.sensor.device());
    }

    pub fn block(self: *Wire) periph.Block {
        return self.controller.block();
    }

    pub fn quiet(self: *const Wire) bool {
        return self.controller.quiet() and self.expander.quiet() and self.sensor.quiet();
    }
};
