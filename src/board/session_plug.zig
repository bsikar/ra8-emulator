//! The session's plug hook for this board (RA8EMU-212): put a catalog part
//! on an endpoint mid-run, or take whatever is there off it.
//!
//! Unplugging leaves each line the way a missing part would. An I2C part
//! leaves its line's registry, so its address phase goes unacknowledged. An
//! SPI channel gets a stand-in that reads MISO floating high (the
//! controller's own empty-channel read is left alone, which keeps recorded
//! runs identical). A UART channel goes silent. A GPIO pin goes back to its
//! pull state.
const std = @import("std");
const endpoint = @import("../periph/model/endpoint.zig");
const parts = @import("../periph/model/parts.zig");
const fault_lines = @import("../periph/model/fault_lines.zig");
const riic_bus = @import("../periph/riic/riic_bus.zig");
const spi = @import("../periph/spi/spi.zig");
const session_api = @import("../debug/session_api.zig");
const plug = @import("plug.zig");
const Board = @import("board.zig").Board;

pub const Error = error{NothingFitted};

/// What an unplugged SPI select reads: nothing drives MISO, so it floats.
pub const floating = struct {
    var unused: u8 = 0;

    fn exchange(_: *anyopaque, _: u8) u8 {
        return fault_lines.floating;
    }

    pub const device: spi.Device = .{ .context = &unused, .exchangeFn = exchange };

    pub fn holds(part: spi.Device) bool {
        return part.context == device.context;
    }
};

pub const Plugs = struct {
    board: *Board,
    arena: std.mem.Allocator,

    pub fn init(board: *Board, arena: std.mem.Allocator) Plugs {
        return .{ .board = board, .arena = arena };
    }

    pub fn hook(self: *Plugs) session_api.PlugHook {
        return .{ .context = self, .plugFn = setErased };
    }

    /// Put a fresh `name` on `at`, or take what is there off it when null.
    pub fn set(self: *Plugs, at: endpoint.Endpoint, name: ?[]const u8) !void {
        const wanted = name orelse return self.unplug(at);
        const made = try parts.all.make(self.arena, wanted, at);
        if (at == .spi) {
            const unit = &self.board.spi.channels[at.spi.channel];
            if (unit.device) |part| if (floating.holds(part)) {
                unit.device = null;
            };
        }
        try plug.one(self.board, made.device, at);
    }

    fn setErased(context: *anyopaque, at: endpoint.Endpoint, name: ?[]const u8) anyerror!void {
        const self: *Plugs = @ptrCast(@alignCast(context));
        try self.set(at, name);
    }

    fn unplug(self: *Plugs, at: endpoint.Endpoint) Error!void {
        switch (at) {
            .i2c => |where| {
                _ = self.line(where.line).detach(where.address) orelse return Error.NothingFitted;
            },
            .spi => |where| {
                const unit = &self.board.spi.channels[where.channel];
                const part = unit.device orelse return Error.NothingFitted;
                if (floating.holds(part)) return Error.NothingFitted;
                unit.device = floating.device;
            },
            .uart => |where| {
                const unit = &self.board.serial.channels[where.channel];
                if (unit.device == null) return Error.NothingFitted;
                unit.device = null;
            },
            .gpio => |where| {
                if (!self.board.pins.wired.detach(where.port, where.pin)) return Error.NothingFitted;
                self.board.pins.release(where.port, where.pin);
            },
        }
    }

    fn line(self: *Plugs, which: endpoint.Line) *riic_bus.Registry {
        return switch (which) {
            .riic => &self.board.wire.controller.devices,
            .touch => &self.board.wire.touchline.devices,
        };
    }
};
