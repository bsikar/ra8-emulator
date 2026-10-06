//! Host tests for the shell loop (RA8EMU-763): a frame presents on the
//! headless platform, quit closes the shell, a gutter drag moves its split,
//! and a local `serve --stdio` session connects and loads a corpus image
//! with the status strip following.
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const proto = ra8.interfaces.rpc.session;
const pane_layout = ra8.gui.pane_layout;
const shell_frame = ra8.gui.shell_frame;
const shell_loop = ra8.gui.shell_loop;
const session_link = ra8.gui.session_link;
const strip = ra8.gui.status_strip;
const Headless = ra8.gui.headless.Headless;

const Env = proto.Client.Env;
const elf_path = "tests/fixtures/fpu/fp_basic.elf";
const width = 480;
const height = 320;

fn shell() !shell_loop.Shell {
    return shell_loop.Shell.init(std.testing.allocator, try pane_layout.twoCore(std.testing.allocator));
}

test "a frame presents the shell frame on the headless platform" {
    var window = Headless.init(std.testing.allocator, width, height);
    defer window.deinit();
    var s = try shell();
    defer s.deinit();
    try std.testing.expect(try s.step(window.platform()));
    try std.testing.expectEqual(@as(u32, 1), window.presents);
    const frame = window.last.?;
    try std.testing.expectEqual(strip.border, frame.at(width - 1, height - strip.height));
    try std.testing.expectEqual(shell_frame.title_fill, frame.at(width / 4, 0));
}

test "quit closes the shell without presenting" {
    var window = Headless.init(std.testing.allocator, width, height);
    defer window.deinit();
    var s = try shell();
    defer s.deinit();
    try window.feed(.quit);
    try std.testing.expect(!try s.step(window.platform()));
    try std.testing.expectEqual(@as(u32, 0), window.presents);
}

test "dragging the root gutter moves its split and lets go on release" {
    var window = Headless.init(std.testing.allocator, width, height);
    defer window.deinit();
    var s = try shell();
    defer s.deinit();
    const root = s.layout.root;
    const before = s.layout.node(root).body.split.ratio;
    var solved = try shell_frame.solve(&s.layout, std.testing.allocator, width, height);
    defer solved.deinit(std.testing.allocator);
    var gap: pane_layout.Rect = undefined;
    for (solved.gutters.items) |found| if (found.split == root) {
        gap = found.area;
    };
    const y = gap.y + @divTrunc(gap.h, 2);
    try window.feed(.{ .button = .{ .button = 1, .down = true, .x = gap.x + 1, .y = y } });
    try window.feed(.{ .pointer = .{ .x = 120, .y = y } });
    try window.feed(.{ .button = .{ .button = 1, .down = false, .x = 120, .y = y } });
    try window.feed(.{ .pointer = .{ .x = 400, .y = y } });
    try std.testing.expect(try s.step(window.platform()));
    const after = s.layout.node(root).body.split.ratio;
    try std.testing.expect(after < before);
    try std.testing.expect(after < 0.3);
    try std.testing.expectEqual(@as(?pane_layout.Gutter, null), s.held);
}

/// Step the shell until `done` holds, for ten seconds.
fn until(s: *shell_loop.Shell, window: *Headless, comptime done: fn (*const shell_loop.Shell) bool) !void {
    const deadline = std.time.milliTimestamp() + 10_000;
    while (!done(s)) {
        if (std.time.milliTimestamp() > deadline) return error.Timeout;
        _ = try s.step(window.platform());
        std.time.sleep(std.time.ns_per_ms);
    }
}

fn connected(s: *const shell_loop.Shell) bool {
    return s.state() == .connected;
}

fn loaded(s: *const shell_loop.Shell) bool {
    return s.status.load_id == null and s.status.pc_id == null and s.status.image != null;
}

test "a local session connects and loads a corpus image through the shell" {
    const gpa = std.testing.allocator;
    var window = Headless.init(gpa, width, height);
    defer window.deinit();
    var s = try shell();
    defer s.deinit();
    var local: session_link.Local = undefined;
    try local.spawn(gpa, test_paths.emulator, elf_path);
    errdefer _ = local.child.kill() catch {};
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: session_link.Link = undefined;
    link.open(local.transport(), rx, tx);
    s.link = &link;
    try until(&s, &window, connected);

    const bytes = try std.fs.cwd().readFileAlloc(gpa, elf_path, 1 << 20);
    defer gpa.free(bytes);
    try s.status.load(&link, elf_path, bytes);
    try until(&s, &window, loaded);
    var buf: [256]u8 = undefined;
    const line = try s.status.text(s.state(), &buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "fp_basic.elf") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "| halted at 0x") != null);
    try std.testing.expectEqual(strip.Tone.halted, strip.tone(&s.status, s.state()));

    link.close();
    local.end();
    _ = try local.reap();
}
