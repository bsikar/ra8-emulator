//! The host on the far end of the USBFS jack, scripted: it takes a device
//! the pull-up attached through standard enumeration, one step per chunk
//! boundary, the way a PC would.
//!
//! Each step sends its SETUP through Device.setup, collects any IN data the
//! driver commits on the DCP, and waits for the driver to end the status
//! stage with CCPL before moving on. SET_ADDRESS needs no wait: the SIE
//! answers it. A step that takes longer than `patience` boundaries ends the
//! script in `failed`, so a driver that never answers cannot hold it forever.
const usbfs = @import("usbfs.zig");

pub const Step = enum {
    waiting,
    device_descriptor,
    set_address,
    config_descriptor,
    set_configuration,
    configured,
    failed,
};

pub const requests = struct {
    pub const address: u8 = 1;
    pub const device_descriptor = [8]u8{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 };
    pub const set_address = [8]u8{ 0x00, 0x05, address, 0x00, 0x00, 0x00, 0x00, 0x00 };
    pub const config_descriptor = [8]u8{ 0x80, 0x06, 0x00, 0x02, 0x00, 0x00, 0x09, 0x00 };
    pub const set_configuration = [8]u8{ 0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };
};

pub const Host = struct {
    step: Step = .waiting,
    /// Whether the current step's SETUP has gone out.
    sent: bool = false,
    /// Boundaries spent on the current step, and how many it may take.
    waited: u32 = 0,
    patience: u32 = 20_000,
    /// What the device returned, for the run report.
    device: [18]u8 = .{0} ** 18,
    config: [9]u8 = .{0} ** 9,
    got: u16 = 0,

    pub fn tick(self: *Host, device: *usbfs.Device) void {
        switch (self.step) {
            .waiting => if (state(device) == usbfs.intsts0.dvsq_default) self.advance(.device_descriptor),
            .device_descriptor => self.read(device, requests.device_descriptor, &self.device, .set_address),
            .set_address => {
                device.setup(requests.set_address);
                self.advance(.config_descriptor);
            },
            .config_descriptor => self.read(device, requests.config_descriptor, &self.config, .set_configuration),
            .set_configuration => self.write(device, requests.set_configuration, .configured),
            .configured, .failed => {},
        }
    }

    pub fn done(self: *const Host) bool {
        return self.step == .configured;
    }

    fn advance(self: *Host, next: Step) void {
        self.step = next;
        self.sent = false;
        self.waited = 0;
        self.got = 0;
    }

    fn patient(self: *Host) bool {
        self.waited += 1;
        if (self.waited <= self.patience) return true;
        self.step = .failed;
        return false;
    }

    /// A control read: SETUP, IN packets until the requested length is in,
    /// then the driver's CCPL.
    fn read(self: *Host, device: *usbfs.Device, packet: [8]u8, into: []u8, next: Step) void {
        if (!self.send(device, packet)) return;
        if (!self.patient()) return;
        var chunk: [64]u8 = undefined;
        if (device.control.hostTake(&chunk)) |len| {
            const n = @min(len, into.len - self.got);
            @memcpy(into[self.got..][0..n], chunk[0..n]);
            self.got += n;
        }
        if (self.got >= into.len and idle(device)) self.advance(next);
    }

    /// A no-data request: SETUP, then the driver's CCPL.
    fn write(self: *Host, device: *usbfs.Device, packet: [8]u8, next: Step) void {
        if (!self.send(device, packet)) return;
        if (!self.patient()) return;
        if (idle(device)) self.advance(next);
    }

    /// True once the SETUP is out; the boundary that sends it does nothing else.
    fn send(self: *Host, device: *usbfs.Device, packet: [8]u8) bool {
        if (self.sent) return true;
        device.setup(packet);
        self.sent = true;
        return false;
    }
};

fn state(device: *const usbfs.Device) u16 {
    return device.interruptStatus() & usbfs.intsts0.dvsq_mask;
}

fn idle(device: *const usbfs.Device) bool {
    return device.interruptStatus() & usbfs.intsts0.ctsq_mask == usbfs.intsts0.ctsq_idle;
}
