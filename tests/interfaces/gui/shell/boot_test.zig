//! A shell started with no image (boot.zig): it runs with no session, and
//! the first image picked starts one on it and loads it, the way
//! `ra8_gui` with no IMAGE does.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const shell_main = gui_app.shell.main;
const Boot = gui_app.shell.boot.Boot;
const Headless = gui_app.headless.Headless;

const Env = ra8.rpc.session.rpc.Client.Env;
const image = "tests/fixtures/fpu/fp_basic.elf";

/// No RA8_HOSTS or HOME: the per-user listener is not bound.
const empty_env: std.process.Environ.Map = .{ .array_hash_map = .empty, .allocator = std.testing.allocator };

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    window: Headless,
    store: gui_app.shell.board_store.Store,
    files: gui_app.shell.open.Open,
    clock: gui_app.wall_clock.Host,
    shell: gui_app.shell.loop.Shell,
    boot: Boot,

    /// The shell and its boot, as main.zig's `local` wires them.
    fn open(self: *Rig) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        self.window = Headless.init(allocator, 480, 320);
        self.store = .{ .io = io, .allocator = allocator, .dir = null };
        self.files = .{ .io = io, .allocator = allocator };
        self.clock = gui_app.wall_clock.Host.init(io);
        self.shell = gui_app.shell.loop.Shell.init(allocator, try gui_app.pane_layout.twoCore(allocator));
        self.shell.files = &self.files;
        self.boot = .{ .allocator = allocator, .io = io, .env = &empty_env, .window = self.window.platform(), .apps = &.{}, .apart = false, .clock = self.clock.clock(), .rx = try allocator.alloc(u8, 2 * Env.max_frame), .tx = try allocator.alloc(u8, Env.max_frame), .store = &self.store, .shell = &self.shell };
        self.shell.boot = self.boot.hook();
    }

    fn deinit(self: *Rig) void {
        self.shell.deinit();
        self.boot.deinit();
        self.arena.deinit();
    }
};

test "with no image the shell runs with no session, and Run has nothing to reach" {
    var rig: Rig = undefined;
    try rig.open();
    defer rig.deinit();
    for (0..3) |_| try std.testing.expect(try rig.shell.step(rig.window.platform()));
    try std.testing.expect(rig.shell.link == null);
    try std.testing.expect(rig.boot.image == null);
    try std.testing.expect(rig.shell.status.image == null);
}

test "the first image picked starts the session on it and loads it" {
    var rig: Rig = undefined;
    try rig.open();
    defer rig.deinit();
    try rig.window.feed(.{ .picked = image });
    try std.testing.expect(try rig.shell.step(rig.window.platform()));
    try std.testing.expectEqualStrings(image, rig.boot.image.?.path);
    try std.testing.expect(rig.shell.link != null);
    try shell_main.drive(std.testing.io, &rig.shell, rig.window.platform(), &rig.boot.image, 2);
    try std.testing.expectEqualStrings("fp_basic.elf", rig.shell.status.image.?.name());
    try std.testing.expectEqualStrings(image, rig.files.path_buf[0..rig.files.path_len]);
}

test "a pick that cannot be read starts nothing and says so" {
    var rig: Rig = undefined;
    try rig.open();
    defer rig.deinit();
    try rig.window.feed(.{ .picked = "tests/fixtures/no-such.elf" });
    try std.testing.expect(try rig.shell.step(rig.window.platform()));
    try std.testing.expect(rig.boot.image == null);
    try std.testing.expect(rig.shell.link == null);
    try std.testing.expectEqual(gui_app.status.bar.Refusal.unread, rig.shell.status.refused.?);
}
