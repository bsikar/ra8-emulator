//! The window the GUI draws into (RA8EMU-617, docs/adr/0001-gui-stack.md):
//! input events in, an RGBA framebuffer out. SDL3 is one backend
//! (RA8EMU-616); headless.zig is another, for tests and the board's
//! golden images. Nothing above this seam knows which one it has.
const raster = @import("raster.zig");

pub const Size = struct { width: u32, height: u32 };

pub const Event = union(enum) {
    quit,
    resize: Size,
    key: struct { code: u32, down: bool },
    pointer: struct { x: i32, y: i32 },
    button: struct { button: u8, down: bool, x: i32, y: i32 },
    wheel: struct { dx: f32, dy: f32 },
};

pub const Platform = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        poll: *const fn (ctx: *anyopaque) ?Event,
        size: *const fn (ctx: *anyopaque) Size,
        scale: *const fn (ctx: *anyopaque) f32,
        present: *const fn (ctx: *anyopaque, frame: *const raster.Framebuffer) anyerror!void,
    };

    /// The next input event, or null once this frame's events are drained.
    pub fn poll(self: Platform) ?Event {
        return self.vtable.poll(self.ctx);
    }

    /// The drawable size in pixels.
    pub fn size(self: Platform) Size {
        return self.vtable.size(self.ctx);
    }

    /// Pixels per logical point (2.0 on a Retina display).
    pub fn scale(self: Platform) f32 {
        return self.vtable.scale(self.ctx);
    }

    /// Show `frame`; the backend copies what it needs before returning.
    pub fn present(self: Platform, frame: *const raster.Framebuffer) !void {
        return self.vtable.present(self.ctx, frame);
    }
};
