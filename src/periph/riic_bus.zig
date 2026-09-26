//! What hangs off the RIIC lines: the device seam and the small registry the
//! controller resolves an address byte through.
//!
//! The RIIC controller in riic.zig drives the bus; it does not know what is on
//! it. A device is three callbacks and a 7-bit address, the same shape the SPI
//! and SCI seams use, so a board decides which parts answer and the controller
//! stays one file about transfers.
const std = @import("std");

/// How an address byte sits on the wire: the 7-bit address in bits 7:1 and the
/// direction in bit 0 (HUM Ch 39.3.2).
pub const wire = struct {
    pub const addr_shift: u3 = 1;
    pub const rnw: u8 = 0x01;
    pub const addr_mask: u8 = 0x7F;

    /// The address byte a controller puts on the line for this target.
    pub fn byte(address: u7, reading: bool) u8 {
        return (@as(u8, address) << addr_shift) | (if (reading) rnw else 0);
    }

    pub fn addressOf(address_byte: u8) u7 {
        return @truncate((address_byte >> addr_shift) & addr_mask);
    }

    pub fn readingOf(address_byte: u8) bool {
        return address_byte & rnw != 0;
    }
};

/// Addresses I2C keeps for itself (I2C-bus specification Rev 7, Table 3):
/// 0x00 is the general call / start byte, and 0x78..0x7F are reserved for
/// 10-bit addressing and device ID. Nothing on a board owns one, so nothing
/// may be registered at one.
pub const reserved = struct {
    pub const general_call: u7 = 0x00;
    pub const first_high: u7 = 0x78;

    pub fn holds(address: u7) bool {
        return address == general_call or address >= first_high;
    }
};

/// Something on the bus. A write hands over one byte; a read fills as much of
/// the caller's buffer as the device has to say and returns how much that was;
/// a stop tells the device the transaction ended, which is where a register
/// pointer usually resets.
pub const Device = struct {
    address: u7,
    context: *anyopaque,
    writeFn: *const fn (*anyopaque, u8) void,
    readFn: *const fn (*anyopaque, []u8) usize,
    stopFn: *const fn (*anyopaque) void,

    pub fn write(self: Device, byte: u8) void {
        self.writeFn(self.context, byte);
    }

    pub fn read(self: Device, into: []u8) usize {
        return self.readFn(self.context, into);
    }

    pub fn stop(self: Device) void {
        self.stopFn(self.context);
    }
};

/// A board's worth of devices. Four is what dev carried and what the EK-RA8D2
/// actually populates; a fifth is a board change, not a runtime condition.
pub const max_devices: usize = 4;

pub const Error = error{
    BusFull,
    ReservedAddress,
    AddressTaken,
};

/// The address -> device map. Nothing here interprets bytes; it only says who
/// answers.
pub const Registry = struct {
    devices: [max_devices]?Device = .{null} ** max_devices,

    pub fn attach(self: *Registry, device: Device) Error!void {
        if (reserved.holds(device.address)) return Error.ReservedAddress;
        if (self.find(device.address) != null) return Error.AddressTaken;
        for (&self.devices) |*slot| {
            if (slot.* == null) {
                slot.* = device;
                return;
            }
        }
        return Error.BusFull;
    }

    pub fn find(self: *Registry, address: u7) ?*Device {
        for (&self.devices) |*slot| {
            if (slot.*) |*device| {
                if (device.address == address) return device;
            }
        }
        return null;
    }

    pub fn count(self: *const Registry) usize {
        var total: usize = 0;
        for (&self.devices) |slot| {
            if (slot != null) total += 1;
        }
        return total;
    }
};
