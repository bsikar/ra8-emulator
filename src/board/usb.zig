//! The board's USB side: which controller this board drives and what is on
//! the far end of it.
//!
//! The EK-RA8D2 has two USB jacks, and the self-loop apps cable them to each
//! other: this controller is the host half of that loop. Whether a device is
//! on the other end is a board fact, so it is set here.
const periph = @import("../periph/registry.zig");
const usbhs = @import("../periph/usbhs.zig");

pub const Usb = struct {
    host: usbhs.Host = .{},

    pub fn attach(self: *Usb, bus: *periph.Bus) periph.Error!void {
        self.host.attachDevice();
        try bus.add(self.host.block());
    }

    pub fn quiet(self: *const Usb) bool {
        return self.host.quiet();
    }
};
