//! The parts the catalog knows: the Click module's LSM6DSO IMU and MAX17048
//! fuel gauge, each wrapped as a model that plugs into an I2C endpoint.
//!
//! The part files stay about the part. This file only says how one is made,
//! freed, and put on a line at an address, so a second gauge at 0x37 is the
//! same model at a different endpoint.
const std = @import("std");
const catalog = @import("catalog.zig");
const endpoint = @import("endpoint.zig");
const lsm6dso = @import("../i3c/i3c_lsm6dso.zig");
const max17048 = @import("../i3c/i3c_max17048.zig");

pub const imu_name = "lsm6dso";
pub const gauge_name = "max17048";

/// Every model a run can name.
pub const all: catalog.Catalog = .{ .models = &models };

const models = [_]catalog.Model{
    I2cPart(lsm6dso.Imu).model(imu_name),
    I2cPart(max17048.Gauge).model(gauge_name),
};

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
