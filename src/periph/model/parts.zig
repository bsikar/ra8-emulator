//! The parts the catalog knows: the Click module's LSM6DSO IMU and MAX17048
//! fuel gauge on I2C, the e-paper panel on SPI, the AT modem on a UART, and
//! a push button and an LED on GPIO pins.
//!
//! The part files stay about the part. This file only says how one is made,
//! freed, and put on a line at an address, so a second gauge at 0x37 is the
//! same model at a different endpoint.
const std = @import("std");
const catalog = @import("catalog.zig");
const endpoint = @import("endpoint.zig");
const eink = @import("../eink/eink.zig");
const gpio_parts = @import("../gpio/gpio_parts.zig");
const lsm6dso = @import("../i3c/i3c_lsm6dso.zig");
const max17048 = @import("../i3c/i3c_max17048.zig");
const modem = @import("../modem/modem.zig");

pub const imu_name = "lsm6dso";
pub const gauge_name = "max17048";
pub const panel_name = "eink";
pub const modem_name = "modem";
pub const button_name = "button";
pub const led_name = "led";

/// Every model a run can name.
pub const all: catalog.Catalog = .{ .models = &models };

const models = [_]catalog.Model{
    I2cPart(lsm6dso.Imu).model(imu_name),
    I2cPart(max17048.Gauge).model(gauge_name),
    ChannelPart(eink.Panel, .spi).model(panel_name),
    ChannelPart(modem.Modem, .uart).model(modem_name),
    ChannelPart(gpio_parts.Button, .gpio).model(button_name),
    ChannelPart(gpio_parts.Led, .gpio).model(led_name),
};

/// A part with a default state and a `device()` on the SPI, SCI or pin seam.
/// The channel or pin is the board's business (src/board/plug.zig), so bind
/// only wraps.
fn ChannelPart(comptime State: type, comptime kind: endpoint.Kind) type {
    return struct {
        fn model(comptime name: []const u8) catalog.Model {
            return .{ .name = name, .kind = kind, .createFn = Owned(State).create, .destroyFn = Owned(State).destroy, .bindFn = bind };
        }

        fn bind(state: *anyopaque, _: endpoint.Endpoint) catalog.Device {
            const part: *State = @ptrCast(@alignCast(state));
            return @unionInit(catalog.Device, @tagName(kind), part.device());
        }
    };
}

/// Make and free one default-initialised `State`.
fn Owned(comptime State: type) type {
    return struct {
        fn create(allocator: std.mem.Allocator) catalog.Error!*anyopaque {
            const state = try allocator.create(State);
            state.* = .{};
            return state;
        }

        fn destroy(allocator: std.mem.Allocator, state: *anyopaque) void {
            allocator.destroy(@as(*State, @ptrCast(@alignCast(state))));
        }
    };
}

/// A part with a default state and a `device()` on the I2C seam, moved to
/// the endpoint's address.
fn I2cPart(comptime Part: type) type {
    return struct {
        fn model(comptime name: []const u8) catalog.Model {
            return .{ .name = name, .kind = .i2c, .createFn = create, .destroyFn = destroy, .bindFn = bind };
        }

        fn create(allocator: std.mem.Allocator) catalog.Error!*anyopaque {
            const part = try allocator.create(Part);
            part.* = .{};
            return part;
        }

        fn destroy(allocator: std.mem.Allocator, state: *anyopaque) void {
            allocator.destroy(@as(*Part, @ptrCast(@alignCast(state))));
        }

        fn bind(state: *anyopaque, at: endpoint.Endpoint) catalog.Device {
            const part: *Part = @ptrCast(@alignCast(state));
            var device = part.device();
            device.address = at.i2c.address;
            return .{ .i2c = device };
        }
    };
}
