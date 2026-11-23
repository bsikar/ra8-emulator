//! Host device allocations and listeners belong to one firmware session.
const std = @import("std");

const setup = @import("ra8_rpc").served_setup;
const usbip = @import("ra8_usbip").exported.run;

pub const Resources = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,

    pub fn open(source: *setup.Served) !*Resources {
        const self = try source.gpa.create(Resources);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(source.gpa), .gpa = source.gpa };
        source.cleanup = .{ .context = self, .closeFn = close };
        return self;
    }

    fn close(ctx: *anyopaque, source: *setup.Served) void {
        const self: *Resources = @ptrCast(@alignCast(ctx));
        usbip.uninstall(&source.owner.board().usb, self.arena.allocator());
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }
};
