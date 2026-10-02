//! Which command lines the debugger front end takes over.
const std = @import("std");
const ra8 = @import("ra8");

const debug_front = ra8.core.debug_front;

test "an ordinary run is left to the ordinary parser" {
    try std.testing.expectEqual(null, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--ms", "2" }));
}

test "a script and the terminal are both asked for after the image" {
    const scripted = debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--debug-script", "s.gdb" }).?;
    try std.testing.expectEqualStrings("s.gdb", (try scripted).script);
    const typed = debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--debug" }).?;
    try std.testing.expectEqual(debug_front.Mode.interactive, try typed);
}

test "a debugger flag mixed with run flags, or missing its file, is bad usage" {
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--debug-script" }).?);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--debug", "--ms", "2" }).?);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--ms", "2", "--debug" }).?);
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "--debug", "fw.elf" }).?);
}
