//! The device models a run can attach by name, and how one is made.
//!
//! A model is a part that is not soldered to the board: a sensor on a Click
//! module, a flash chip, a second fuel gauge. The bus controllers already
//! take their devices through one seam each (riic_bus.Device, spi.Device,
//! sci_device.Device), so the catalog adds no seam of its own. It names a
//! model, says which kind of endpoint it plugs into, and makes an instance
//! that hands back that bus's Device. The controllers never learn that a
//! model exists.
const std = @import("std");
const endpoint = @import("endpoint.zig");
const riic_bus = @import("../riic/riic_bus.zig");
const sci_device = @import("../sci/sci_device.zig");
const spi = @import("../spi/spi.zig");

/// What an instance offers its bus. GPIO joins with RA8EMU-490.
pub const Device = union(enum) {
    i2c: riic_bus.Device,
    spi: spi.Device,
    uart: sci_device.Device,
};

/// One attached model: the device its bus talks to and the state behind
/// it, which `Catalog.destroy` gives back.
pub const Instance = struct {
    model: *const Model,
    device: Device,
    state: *anyopaque,
};

pub const Model = struct {
    name: []const u8,
    kind: endpoint.Kind,
    /// Allocate the model's state for this endpoint and hand back its
    /// device. The endpoint is already known to be of `kind`.
    makeFn: *const fn (std.mem.Allocator, endpoint.Endpoint) Error!Made,
    destroyFn: *const fn (std.mem.Allocator, *anyopaque) void,
};

/// What a model's makeFn returns.
pub const Made = struct {
    device: Device,
    state: *anyopaque,
};

pub const Error = error{
    UnknownModel,
    WrongEndpoint,
    OutOfMemory,
};

pub const Catalog = struct {
    models: []const Model,

    pub fn find(self: Catalog, name: []const u8) ?*const Model {
        for (self.models) |*model| {
            if (std.mem.eql(u8, model.name, name)) return model;
        }
        return null;
    }

    pub fn make(
        self: Catalog,
        allocator: std.mem.Allocator,
        name: []const u8,
        at: endpoint.Endpoint,
    ) Error!Instance {
        const model = self.find(name) orelse return Error.UnknownModel;
        if (model.kind != at.kind()) return Error.WrongEndpoint;
        const made = try model.makeFn(allocator, at);
        return .{ .model = model, .device = made.device, .state = made.state };
    }

    pub fn destroy(allocator: std.mem.Allocator, instance: Instance) void {
        instance.model.destroyFn(allocator, instance.state);
    }
};
