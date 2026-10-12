//! The shell loop (RA8EMU-763): one frame of the debugger shell. It drains the window's events
//! (quit, the menu strip RA8EMU-957, gutter drags) and pumps the session link into the status bar,
//! console, board, device, camera and plug models, whose leaves take clicks and typing, and the
//! registers leaves, read again after a load or a stop. The menu strip (RA8EMU-968), the pane
//! titles (RA8EMU-800) and the settings page (RA8EMU-963) take their presses, and while Run is
//! lit each frame pays the board its slices on the shell's own thread, so the frame never waits
//! on more than one slice. Then it draws the shell frame (RA8EMU-764) through the platform seam,
//! so SDL and the headless platform run it alike.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const widget_paint = @import("ra8_render").widget_paint;
const raster = @import("ra8_render").raster;
const font = @import("ra8_render").font;
pub const frame_buffer = @import("frame_buffer.zig");
const platform = @import("../platform.zig");
/// A session served in this process, answering on the shell's own thread.
const Server = @import("server.zig").Server;
const pane_layout = @import("../ui/pane_layout.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const status_capture = @import("../status/capture.zig");
const status_bar = @import("../status/bar.zig");
const session_link = @import("../session_link.zig");
const shell_console = @import("console.zig");
const shell_board = @import("board/board.zig");
const shell_board_input = @import("board/input.zig");
const shell_devices = @import("devices.zig");
const shell_fault = @import("fault.zig");
const shell_camera = @import("camera/camera.zig");
const shell_titles = @import("titles.zig");
const shell_plug = @import("plug.zig");
const shell_camera_file = @import("camera/file.zig");
const shell_startup = @import("startup.zig");
const shell_open = @import("open.zig");
const shell_registers = @import("registers.zig");
const shell_register_edit = @import("register_edit.zig");
const shell_memory = @import("memory.zig");
const shell_breaks = @import("breaks.zig");
const shell_memory_field = @import("memory_field.zig");
const shell_time = @import("time.zig");
const wall_clock = @import("../wall_clock.zig");
const shell_stack = @import("stack.zig");
const shell_theme = @import("theme.zig");
const menu_bar = @import("../menu_bar.zig");
const menu_actions = @import("menu_actions.zig");
const shell_settings = @import("settings_page.zig");

/// Most arrivals taken off the link in one frame, so a chatty session cannot starve the window.
pub const max_arrivals: usize = 64;

pub const Shell = struct {
    allocator: std.mem.Allocator,
    layout: pane_layout.Layout,
    status: status_bar.Status = .{},
    link: ?*session_link.Link = null,
    painter: ?shell_frame.Painter = null,
    /// The palette in use and the picker that changes it (RA8EMU-1165).
    themes: shell_theme.Themes = .{},
    titles: shell_titles.Tracker = .{}, // a deck tab press holds a drag (RA8EMU-958).
    /// The settings page over the shell (RA8EMU-963).
    settings: shell_settings.Page = .{},
    console: ?*shell_console.Console = null,
    board: ?*shell_board.Board = null,
    /// The pointer on the board leaf: switch clicks and panel touches.
    board_input: ?*shell_board_input.Pointer = null,
    devices: ?*shell_devices.Devices = null,
    /// Each device row's fault mode (RA8EMU-817), stepped by its cell.
    faults: ?*shell_fault.Faults = null,
    camera: ?*shell_camera.Camera = null,
    plug: ?*shell_plug.Plug = null,
    camera_file: ?*shell_camera_file.CameraFile = null,
    /// The `--attach` and `--click` plugs, sent once the image is loaded.
    startup: ?*shell_startup.Startup = null,
    /// Whether the session has answered the image load.
    loaded: bool = false,
    registers: ?*shell_registers.Pair = null,
    /// Register edits from the registers leaves (RA8EMU-946).
    edit: ?*shell_register_edit.Editor = null,
    memory: ?*shell_memory.Pair = null,
    /// The memory leaf's address field for typed symbols (RA8EMU-934).
    memory_field: ?*shell_memory_field.Pin = null,
    code: ?*shell_memory.Pair = null,
    /// The run-to points clicked on the disassembly leaves (RA8EMU-1171).
    breaks: ?*shell_breaks.Breaks = null,
    /// The call stack leaves, walked again after a load and every stop.
    stack: ?*shell_stack.Pair = null,
    /// The time bar's models: the run, the speed field and the clock.
    time: ?*shell_time.Time = null,
    /// Opening another image from the OS's file picker (RA8EMU-959).
    files: ?*shell_open.Open = null,
    /// The session when it is served in this process; null for a remote one.
    server: ?Server = null,
    /// The per-user listener outside clients connect to (RA8EMU-1156).
    listener: ?Server = null,
    /// The wall clock a run is paced against; without one time stands still.
    clock: ?wall_clock.Clock = null,
    /// The last pump took everything the session had sent.
    drained: bool = true,
    /// Where the time bar was drawn this frame.
    bar: draw_list.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The splitter being dragged, from its button press to its release.
    held: ?pane_layout.Gutter = null,
    /// The menu strip's state (RA8EMU-957) and the window's width.
    menu: menu_bar.Menu = .{},
    width: i32 = 0,
    /// The window's height this frame (RA8EMU-963).
    height: i32 = 0,
    /// Where the pointer last was, for the wheel and page keys.
    pointer_at: struct { x: i32, y: i32 } = .{ .x = -1, .y = -1 },
    open: bool = true,
    frame: ?raster.Framebuffer = null,

    /// The shell owns `layout` from here on.
    pub fn init(allocator: std.mem.Allocator, layout: pane_layout.Layout) Shell {
        return .{ .allocator = allocator, .layout = layout };
    }

    pub fn deinit(self: *Shell) void {
        if (self.frame) |*frame| frame.deinit(self.allocator);
        self.layout.deinit();
    }

    /// The link's state, or closed when the shell has none.
    pub fn state(self: *const Shell) session_link.State {
        const link = self.link orelse return .closed;
        return link.state;
    }

    /// Run one frame. False once the window has asked to close.
    pub fn step(self: *Shell, window: platform.Platform) !bool {
        const size = window.size();
        const width: i32 = @intCast(size.width);
        const height: i32 = @intCast(size.height);
        var solved = try shell_frame.solve(&self.layout, self.allocator, width, height);
        defer solved.deinit(self.allocator);
        self.bar = shell_frame.barArea(width, height);
        self.height = height;
        menu_actions.observe(self, window, width);
        while (window.poll()) |event| {
            if (event == .appearance) self.themes.restyle(window.appearance());
            self.handle(window, event, &solved);
        }
        if (!self.open) return false;
        if (!self.themes.styled) self.themes.restyle(window.appearance());
        try self.exchange();
        try self.paySlices();
        if (self.files) |files| files.frame(window, &self.status);
        if (!window.visible()) return true;
        solved.deinit(self.allocator);
        solved = try shell_frame.solve(&self.layout, self.allocator, width, height);
        var list = draw_list.DrawList.init(self.allocator, size.width, size.height);
        defer list.deinit();
        if (self.board) |board| board.pace(self.now());
        try shell_frame.draw(&list, self.themes.active, .{
            .layout = &self.layout,
            .solved = &solved,
            .strip = status_capture.strip(&self.status, self.state()),
            .bar = if (self.time) |time| time.view(&self.status) else .{},
            .menu = self.menu,
            .width = width,
            .height = height,
            .painter = self.painter,
            .themes = self.themes.view(),
        });
        var target = widget_paint.Target{ .list = &list };
        const paint = target.paint();
        try shell_settings.Page.draw(&self.settings, &paint, &self.themes, self.themes.active, width, height);
        if (try window.show(&list, font.atlas)) return true;
        // raster.draw is the documented temporary composite (RA8EMU-1157).
        const frame = try frame_buffer.fit(&self.frame, self.allocator, size);
        raster.draw(frame, &list, font.atlas);
        try window.present(frame);
        return true;
    }

    /// Apply one input event against this frame's layout.
    pub fn handle(self: *Shell, window: platform.Platform, event: platform.Event, solved: *const pane_layout.Solved) void {
        switch (event) {
            .quit => self.open = false,
            .button => |press| {
                if (press.button != 1) return;
                if (press.down and menu_actions.press(self, window, press.x, press.y)) return;
                if (press.down and self.themes.press(shell_frame.stripUnder(self.bar), press.x, press.y)) return;
                self.held = if (press.down) solved.hit(press.x, press.y) else null;
                if (!press.down) return self.releaseBoard(solved, press.x, press.y);
                if (self.held != null) return;
                if (self.pressFields(press.x, press.y)) return;
                if (self.pressValue(press.x, press.y, solved)) return;
                if (self.titles.press(&self.layout, solved, press.x, press.y)) return;
                if (self.pressBoard(solved, press.x, press.y)) return;
                if (self.link) |link| if (self.pressLink(link, solved, press.x, press.y)) return;
                if (self.registers) |registers| if (registers.clickIn(&self.layout, solved, press.x, press.y)) return;
                if (self.console) |console| if (console.clickIn(&self.layout, solved, press.x, press.y)) return;
                const camera = self.camera orelse return;
                _ = camera.clickIn(&self.layout, solved, press.x, press.y);
            },
            .pointer => |at| {
                self.pointer_at = .{ .x = at.x, .y = at.y };
                const found = self.held orelse return self.moveBoard(at.x, at.y);
                const axis = self.layout.node(found.split).body.split.axis;
                self.layout.drag(found, if (axis == .across) at.x else at.y);
            },
            .wheel => |turn| {
                const console = self.console orelse return;
                _ = console.wheelIn(&self.layout, solved, self.pointer_at.x, self.pointer_at.y, turn.dy);
            },
            .text, .key => {
                if (menu_actions.key(self, window, event)) return;
                if (self.edit) |edit| if (self.link) |link| if (edit.handle(link, event)) return;
                if (self.themes.key(event)) return;
                if (self.pageConsole(event, solved)) return;
                if (self.time) |time| if (self.link) |link| if (time.handle(event, link)) return;
                if (self.plug) |plug| _ = plug.handle(event);
                if (self.camera_file) |file| _ = file.handle(event);
                if (self.memory_field) |field| _ = field.handle(event);
            },
            .picked => |path| if (self.files) |files| if (self.link) |link| files.picked(path, link, &self.status),
            else => {},
        }
    }

    /// Page Up or Page Down over a console leaf (RA8EMU-1122).
    fn pageConsole(self: *Shell, event: platform.Event, solved: *const pane_layout.Solved) bool {
        const key = switch (event) {
            .key => |key| key,
            else => return false,
        };
        const console = self.console orelse return false;
        if (!key.down) return false;
        return console.pageIn(&self.layout, solved, self.pointer_at.x, self.pointer_at.y, key.code);
    }

    /// Offer a press to the register editor over a value cell.
    fn pressValue(self: *Shell, x: i32, y: i32, solved: *const pane_layout.Solved) bool {
        const edit = self.edit orelse return false;
        const registers = self.registers orelse return false;
        return edit.press(registers, &self.layout, solved, x, y);
    }

    /// Offer a press to the text fields and the time bar.
    fn pressFields(self: *Shell, x: i32, y: i32) bool {
        const in_plug = if (self.plug) |plug| plug.press(x, y) else false;
        const in_file = if (self.camera_file) |file| file.press(x, y) else false;
        const in_memory = if (self.memory_field) |field| field.press(x, y) else false;
        return self.pressBar(x, y) or in_plug or in_file or in_memory;
    }

    fn pressBar(self: *Shell, x: i32, y: i32) bool {
        const time = self.time orelse return false;
        const link = self.link orelse return false;
        return time.press(self.bar, x, y, &self.status, link);
    }

    /// Board time for an input: what the time bar last knew, or zero.
    fn boardNow(self: *const Shell) u64 {
        const time = self.time orelse return 0;
        return time.boardNow();
    }

    /// A pane changed the device list: the shell's rows are stale.
    fn wants(self: *Shell) void {
        if (self.devices) |devices| devices.want = true;
    }

    /// Offer a press to the session-backed panes: faults, devices, run-to points.
    fn pressLink(self: *Shell, link: *session_link.Link, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        const devices = self.devices orelse return false;
        if (self.faults) |faults| if (faults.clickIn(link, devices, &self.layout, solved, x, y)) return true;
        if (devices.clickIn(link, &self.layout, solved, x, y)) return true;
        if (self.breaks) |breaks| if (self.code) |code| if (breaks.clickIn(link, code, &self.layout, solved, x, y)) return true;
        return false;
    }

    /// Offer a left press to the board leaf: a switch, or the panel.
    fn pressBoard(self: *Shell, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        const pointer = self.board_input orelse return false;
        const board = self.board orelse return false;
        return pointer.down(board, &self.layout, solved, x, y, self.boardNow());
    }

    fn moveBoard(self: *Shell, x: i32, y: i32) void {
        const pointer = self.board_input orelse return;
        const board = self.board orelse return;
        pointer.move(board, x, y);
    }

    /// The left button came up: the board leaf sends the click or touch under way.
    fn releaseBoard(self: *Shell, solved: *const pane_layout.Solved, x: i32, y: i32) void {
        if (self.titles.release(&self.layout, solved, x, y)) return;
        const pointer = self.board_input orelse return;
        const board = self.board orelse return;
        const link = self.link orelse return;
        pointer.up(board, link, x, y, self.boardNow());
    }
    /// The wall clock, or zero for a shell that was given none.
    fn now(self: *const Shell) u64 {
        const clock = self.clock orelse return 0;
        return clock.now();
    }

    /// One round with the session: send what is due and take what has
    /// arrived, and when the session is served in this process let it answer
    /// and take that too.
    fn exchange(self: *Shell) !void {
        try self.pump();
        if (self.server) |server| try server.answer();
        if (self.listener) |listener| try listener.answer();
        try self.pump();
    }

    /// Pay what this frame owes a lit run (shell_run.zig), one slice at a
    /// time, each answered and taken before the next goes out; a session
    /// in another process answers in its own time, one slice a frame.
    fn paySlices(self: *Shell) !void {
        const time = self.time orelse return;
        const link = self.link orelse return;
        defer self.settle();
        time.frame(link, self.now());
        // No slice goes out behind a load: the image it would run may be gone.
        while (self.drained and self.status.load_id == null and time.run.next(link, self.now())) {
            const server = self.server orelse return;
            try server.answer();
            if (self.listener) |listener| try listener.answer();
            try self.pump();
        }
    }

    /// A pause the time bar settled: the status bar shows the halt, and the
    /// core's leaves read it again.
    fn settle(self: *Shell) void {
        const time = self.time orelse return;
        if (!time.settle(&self.status)) return;
        if (self.registers) |registers| registers.refresh();
        if (self.stack) |stack| stack.refresh();
    }

    /// Feed what the session sent into the status bar model and the leaves.
    pub fn pump(self: *Shell) !void {
        const link = self.link orelse return;
        if (self.console) |console| console.attach(link);
        if (self.board) |board| board.attach(link);
        if (self.devices) |devices| devices.attach(link);
        if (self.camera_file) |file| if (self.camera) |camera| {
            _ = file.apply(camera);
        };
        if (self.camera) |camera| camera.attach(link);
        if (self.plug) |plug| _ = plug.attach(link);
        if (self.startup) |startup| if (self.loaded) startup.attach(link);
        if (self.registers) |registers| registers.attach(link);
        if (self.memory_field) |field| _ = field.submit(self.memory);
        if (self.memory) |memory| memory.attach(link);
        if (self.code) |code| code.attach(link);
        if (self.breaks) |breaks| breaks.attach(link);
        if (self.stack) |stack| stack.attach(link);
        self.drained = false;
        var taken: usize = 0;
        while (taken < max_arrivals) : (taken += 1) {
            const arrival = link.pump() orelse {
                self.drained = true;
                break;
            };
            // A slice's end is not a stop: the run goes on.
            if (self.time) |time| if (time.observe(arrival, self.now()) == .boundary) continue;
            const loading = self.status.load_id;
            self.status.observe(link, arrival);
            const answered = loading != null and self.status.load_id == null;
            if (answered) self.loaded = true;
            if (answered) if (self.time) |time| time.loaded(&self.status);
            self.observeCore(answered, arrival);
            if (self.console) |console| try console.observe(arrival);
            if (self.board) |board| try board.observe(arrival, self.now());
            if (self.devices) |devices| devices.observe(arrival);
            if (self.faults) |faults| if (faults.observe(arrival)) self.wants();
            if (self.camera) |camera| camera.observe(arrival);
            if (self.plug) |plug| if (plug.observe(arrival)) self.wants();
            if (self.startup) |startup| if (startup.observe(arrival)) self.wants();
        }
        self.settle();
    }

    /// The stack, registers, memory and code leaves: start over after a
    /// load, take the arrival, and follow each core's fresh registers.
    fn observeCore(self: *Shell, loaded: bool, arrival: session_link.Arrival) void {
        if (self.stack) |stack| {
            if (loaded) stack.reload();
            stack.observe(arrival);
        }
        const registers = self.registers orelse return;
        if (loaded) registers.reload();
        registers.observe(arrival);
        if (self.edit) |edit| _ = edit.observe(registers, arrival);
        for ([_]?*shell_memory.Pair{ self.memory, self.code }) |leaf| if (leaf) |memory| {
            if (loaded) memory.reload();
            memory.observe(arrival);
            memory.follow(registers);
        };
    }
};
