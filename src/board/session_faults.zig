//! The session's fault hook for parts on this board's I2C lines (RA8EMU-520).
//!
//! The first set on a part wraps it where it sits in its line's registry, in
//! a fault.I2c on the run's clock. Every later set or clear only changes that
//! same wrapper's mode, so setting and clearing mid-run never stacks
//! wrappers; a cleared part passes straight through. bus_low is a fact about
//! the line, not the part: setting it holds the line low, and clearing any
//! part on that line lets it go. SPI and UART channels are not covered yet.
const std = @import("std");
const endpoint = @import("../periph/model/endpoint.zig");
const fault = @import("../periph/model/fault.zig");
const fault_spec = @import("../periph/model/fault_spec.zig");
const riic_bus = @import("../periph/riic/riic_bus.zig");
const session_api = @import("../debug/session_api.zig");
const Board = @import("board.zig").Board;

pub const Error = error{ WrongEndpoint, NothingFitted, TooManyFaults } || std.mem.Allocator.Error;

/// Parts that can carry a session fault at once: every slot on both lines.
pub const max_wrapped: usize = 2 * riic_bus.max_devices;

pub const Faults = struct {
    board: *Board,
    arena: std.mem.Allocator,
    wrapped: [max_wrapped]?*fault.I2c = .{null} ** max_wrapped,

    pub fn init(board: *Board, arena: std.mem.Allocator) Faults {
        return .{ .board = board, .arena = arena };
    }

    pub fn hook(self: *Faults) session_api.FaultHook {
        return .{ .context = self, .setFn = setErased };
    }

    /// Put the part on `at` into `mode`, or back to itself when null.
    pub fn set(self: *Faults, at: endpoint.Endpoint, mode: ?fault_spec.Mode) Error!void {
        if (at != .i2c) return Error.WrongEndpoint;
        const registry = self.line(at.i2c.line);
        const found = registry.find(at.i2c.address) orelse return Error.NothingFitted;
        const wanted = mode orelse {
            registry.hold(false);
            if (self.wrapperOf(found)) |wrapper| wrapper.set(.none);
            return;
        };
        if (wanted == .bus_low) return registry.hold(true);
        const wrapper = try self.wrap(found);
        wrapper.set(fault_spec.i2cMode(wanted));
    }

    fn setErased(context: *anyopaque, at: endpoint.Endpoint, mode: ?fault_spec.Mode) anyerror!void {
        const self: *Faults = @ptrCast(@alignCast(context));
        try self.set(at, mode);
    }

    fn line(self: *Faults, which: endpoint.Line) *riic_bus.Registry {
        return switch (which) {
            .riic => &self.board.wire.controller.devices,
            .touch => &self.board.wire.touchline.devices,
        };
    }

    /// The wrapper this hook already put around `slot`, if any.
    fn wrapperOf(self: *Faults, slot: *riic_bus.Device) ?*fault.I2c {
        for (self.wrapped) |entry| {
            const wrapper = entry orelse continue;
            if (slot.context == @as(*anyopaque, wrapper)) return wrapper;
        }
        return null;
    }

    fn wrap(self: *Faults, slot: *riic_bus.Device) Error!*fault.I2c {
        if (self.wrapperOf(slot)) |wrapper| return wrapper;
        for (&self.wrapped) |*entry| {
            if (entry.* != null) continue;
            const wrapper = try self.arena.create(fault.I2c);
            wrapper.* = fault.I2c.timed(slot.*, &self.board.time.base);
            slot.* = wrapper.device();
            entry.* = wrapper;
            return wrapper;
        }
        return Error.TooManyFaults;
    }
};
