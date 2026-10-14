//! The window the GUI draws into (RA8EMU-617, ADR 0001 in the knowledge base, RA8EMU-A-8):
//! input events in, an RGBA framebuffer out. SDL3 is one backend
//! (RA8EMU-616); headless.zig is another, for tests and the board's
//! golden images. Nothing above this seam knows which one it has.
const draw_list = @import("ra8_render").draw_list;
const raster = @import("ra8_render").raster;

pub const Size = struct { width: u32, height: u32 };

/// Text the window typed (SDL text input: shifted and composed
/// characters), first bytes of its UTF-8 kept.
pub const Text = struct {
    bytes: [8]u8 = undefined,
    len: u8 = 0,

    pub fn of(utf8: []const u8) Text {
        var text = Text{};
        const count = @min(utf8.len, text.bytes.len);
        @memcpy(text.bytes[0..count], utf8[0..count]);
        text.len = @intCast(count);
        return text;
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Whether the OS is set to a light or dark appearance (RA8EMU-962).
/// Unknown when the backend or the desktop gives no answer.
pub const Appearance = enum { unknown, light, dark };

pub const Event = union(enum) {
    quit,
    /// The OS appearance changed; read it again with `appearance`.
    appearance,
    resize: Size,
    /// The window was uncovered and must be drawn again.
    expose,
    key: struct {
        code: u32,
        down: bool,
        /// The OS's shortcut modifier was held: Cmd on macOS, Ctrl elsewhere.
        primary: bool = false,
        /// The shift modifier was held with the key.
        shift: bool = false,
    },
    text: Text,
    pointer: struct { x: i32, y: i32 },
    button: struct { button: u8, down: bool, x: i32, y: i32 },
    wheel: struct { dx: f32, dy: f32 },
    /// The image chosen in the picker `openImage` put up (RA8EMU-959). The
    /// path is the backend's and holds until the next poll; a picker that
    /// was cancelled sends nothing.
    picked: []const u8,
    /// The board profile chosen in the picker `openProfile` put up
    /// (RA8EMU-1152). The path is the backend's and holds until the next
    /// poll; a picker that was cancelled sends nothing.
    picked_profile: []const u8,
    /// A file dropped onto the window (RA8EMU-1153). The path is the
    /// backend's and holds until the next poll.
    dropped: []const u8,
};

/// How an executable opens and closes its window. ra8_gui passes
/// sdl/opener.zig's SDL window to the shell; a test passes a headless one.
/// A window's saved geometry (RA8EMU-966): its size in points, where it
/// sat on the screen, and whether it was full screen. x and y are null
/// when the saved state has no position.
pub const WindowState = struct {
    width: u32,
    height: u32,
    x: ?i32 = null,
    y: ?i32 = null,
    fullscreen: bool = false,
};

/// Where a window sits on the screen (RA8EMU-966).
pub const Pos = struct { x: i32, y: i32 };

/// `open` is null when no window can be had; the shell hands it the saved
/// geometry to open at, or null for the backend's default.
pub const Opener = struct {
    open: *const fn (saved: ?WindowState) ?Platform,
    close: *const fn () void,
};

pub const Platform = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        poll: *const fn (ctx: *anyopaque) ?Event,
        size: *const fn (ctx: *anyopaque) Size,
        scale: *const fn (ctx: *anyopaque) f32,
        present: *const fn (ctx: *anyopaque, frame: *const raster.Framebuffer) anyerror!void,
        /// Draws and shows a list on the backend itself (SDL geometry,
        /// RA8EMU-739). Null, or false back, means rasterize and present.
        show: ?*const fn (ctx: *anyopaque, list: *const draw_list.DrawList, atlas: ?raster.Atlas) anyerror!bool = null,
        /// The least time between presents (RA8EMU-732); null is no cap.
        interval: ?*const fn (ctx: *anyopaque) u64 = null,
        /// Makes a present wait for the display's refresh, or not, and says
        /// whether it now does; null for a backend with no display to wait on.
        set_vsync: ?*const fn (ctx: *anyopaque, on: bool) bool = null,
        /// The refresh rate of the display the window is on, in thousandths
        /// of a hertz; null, or 0 back, when it is not known.
        refresh: ?*const fn (ctx: *anyopaque) u32 = null,
        /// The OS light or dark setting (RA8EMU-962); null is unknown.
        appearance: ?*const fn (ctx: *anyopaque) Appearance = null,
        /// Raises the window to the front (RA8EMU-1156); null on backends
        /// that have no window to raise.
        focus: ?*const fn (ctx: *anyopaque) void = null,
        /// Puts up the OS's own file picker for a firmware image
        /// (RA8EMU-959) and returns at once; the choice comes back as a
        /// `picked` event. Null for a backend with no picker.
        open_image: ?*const fn (ctx: *anyopaque) void = null,
        /// Puts up the OS's own file picker for a board profile
        /// (RA8EMU-1152) and returns at once; the choice comes back as a
        /// `picked_profile` event. Null for a backend with no picker.
        open_profile: ?*const fn (ctx: *anyopaque) void = null,
        /// Sets the window's title; null for a backend with none.
        title: ?*const fn (ctx: *anyopaque, text: []const u8) void = null,
        /// Toggles the window's full-screen state (RA8EMU-966); null for a
        /// backend with no window to toggle.
        toggle_fullscreen: ?*const fn (ctx: *anyopaque) void = null,
        /// Whether the window is full screen (RA8EMU-966); null is never.
        fullscreen: ?*const fn (ctx: *anyopaque) bool = null,
        /// False while minimized or hidden; null means drawable.
        visible: ?*const fn (ctx: *anyopaque) bool = null,
        /// Where the window sits on the screen (RA8EMU-966); null when the
        /// backend does not say.
        position: ?*const fn (ctx: *anyopaque) ?Pos = null,
    };

    /// The next input event, or null once this frame's events are drained.
    pub fn poll(self: Platform) ?Event {
        return self.vtable.poll(self.ctx);
    }

    /// The drawable size in pixels.
    pub fn size(self: Platform) Size {
        return self.vtable.size(self.ctx);
    }

    /// Whether painting can reach a visible window. Transport still pumps.
    pub fn visible(self: Platform) bool {
        const get = self.vtable.visible orelse return true;
        return get(self.ctx);
    }

    /// Pixels per logical point (2.0 on a Retina display).
    pub fn scale(self: Platform) f32 {
        return self.vtable.scale(self.ctx);
    }

    /// Show `frame`; the backend copies what it needs before returning.
    pub fn present(self: Platform, frame: *const raster.Framebuffer) !void {
        return self.vtable.present(self.ctx, frame);
    }

    /// Show `list` drawn by the backend. False when the backend has no
    /// such path or gave it up, so the caller rasterizes into a
    /// framebuffer and calls present: the CPU path stays the fallback.
    pub fn show(self: Platform, list: *const draw_list.DrawList, atlas: ?raster.Atlas) !bool {
        const backend_show = self.vtable.show orelse return false;
        return backend_show(self.ctx, list, atlas);
    }

    /// Nanoseconds the next present must wait after the last; 0 is no cap.
    pub fn interval(self: Platform) u64 {
        const get = self.vtable.interval orelse return 0;
        return get(self.ctx);
    }

    /// Ask that a present wait for the display's refresh, or not. Returns
    /// whether presents wait now; false on a backend that cannot.
    pub fn setVsync(self: Platform, on: bool) bool {
        const set = self.vtable.set_vsync orelse return false;
        return set(self.ctx, on);
    }

    /// The window's display refresh rate in thousandths of a hertz, or 0
    /// when the backend does not know it.
    pub fn refresh(self: Platform) u32 {
        const get = self.vtable.refresh orelse return 0;
        return get(self.ctx);
    }

    /// The OS light or dark setting, or unknown when the backend has none.
    pub fn appearance(self: Platform) Appearance {
        const get = self.vtable.appearance orelse return .unknown;
        return get(self.ctx);
    }

    /// Raise the window to the front; a no-op on backends without one.
    pub fn focus(self: Platform) void {
        const raise = self.vtable.focus orelse return;
        raise(self.ctx);
    }

    /// Put up the OS's file picker for a firmware image. It does not wait:
    /// a choice arrives later as a `picked` event. False when the backend
    /// has no picker.
    pub fn openImage(self: Platform) bool {
        const put_up = self.vtable.open_image orelse return false;
        put_up(self.ctx);
        return true;
    }

    /// Put up the OS's file picker for a board profile. It does not wait:
    /// a choice arrives later as a `picked_profile` event. False when the
    /// backend has no picker.
    pub fn openProfile(self: Platform) bool {
        const put_up = self.vtable.open_profile orelse return false;
        put_up(self.ctx);
        return true;
    }

    /// Set the window's title, on a backend that has one.
    /// Ask the window to enter or leave full screen (RA8EMU-966); nothing
    /// happens on a backend with no window to toggle.
    pub fn toggleFullscreen(self: Platform) void {
        const toggle = self.vtable.toggle_fullscreen orelse return;
        toggle(self.ctx);
    }

    /// Whether the window is full screen (RA8EMU-966); false when the
    /// backend does not say.
    pub fn fullscreen(self: Platform) bool {
        const get = self.vtable.fullscreen orelse return false;
        return get(self.ctx);
    }

    /// Where the window sits on the screen (RA8EMU-966); null when the
    /// backend does not say.
    pub fn position(self: Platform) ?Pos {
        const get = self.vtable.position orelse return null;
        return get(self.ctx);
    }

    pub fn title(self: Platform, text: []const u8) void {
        const set = self.vtable.title orelse return;
        set(self.ctx, text);
    }
};
