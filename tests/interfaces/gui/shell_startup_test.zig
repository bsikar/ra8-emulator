//! Tests for src/interfaces/gui/shell_startup.zig and the shell flags that
//! fill it (RA8EMU-1095): the window's `--attach`, `--click`,
//! `--camera-source` and `--window-stills` reach the shell.
const std = @import("std");
const ra8 = @import("ra8");

const shell_main = ra8.core.shell_main;
const shell_startup = ra8.core.shell_startup;

test "the click parts are ones the catalog takes" {
    var startup: shell_startup.Startup = .{};
    try startup.addClick();
    try std.testing.expectEqual(@as(usize, 2), startup.count);
    try std.testing.expect(startup.pending());
}

test "an unknown model is refused before the window opens" {
    var startup: shell_startup.Startup = .{};
    try std.testing.expectError(error.UnknownModel, startup.add("nope@i2c:touch@0x40"));
    try std.testing.expectEqual(@as(usize, 0), startup.count);
    try std.testing.expect(!startup.pending());
}

test "more plugs than a run may fit are refused" {
    var startup: shell_startup.Startup = .{};
    for (0..shell_startup.max_plugs) |_| try startup.add(shell_startup.click_plugs[0]);
    try std.testing.expectError(error.TooManyPlugs, startup.add(shell_startup.click_plugs[1]));
}

test "the window's startup flags are kept around the image" {
    const args = try shell_main.parse(&.{ "ra8_gui", "shell", "--click", "--attach", "max17048@i2c:touch@0x37", "app.elf", "--camera-source", "gradient", "--window-stills", "/tmp/stills", "--window-stills-every", "3" });
    try std.testing.expectEqualStrings("app.elf", args.image);
    try std.testing.expectEqual(@as(usize, 3), args.startup.count);
    try std.testing.expectEqualStrings("max17048@i2c:touch@0x37", args.startup.plugs[2]);
    try std.testing.expectEqual(true, args.camera.?.kind == .gradient);
    try std.testing.expectEqualStrings("/tmp/stills", args.stills.?);
    try std.testing.expectEqual(@as(u32, 3), args.stills_every);
}

test "a bad attach, camera source or stills count is a usage error" {
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "shell", "--attach", "nope@x", "app.elf" }));
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "shell", "--camera-source", "nope", "app.elf" }));
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "shell", "--window-stills-every", "0", "app.elf" }));
    try std.testing.expectError(error.Usage, shell_main.parse(&.{ "ra8_gui", "shell", "app.elf", "--attach" }));
}
