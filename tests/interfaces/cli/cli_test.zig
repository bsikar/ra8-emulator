//! Tests for src/core/cli.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.cli;

const parse = mod.parse;
const Part = ra8.core.part.Part;

test "the command line takes an image and an optional instruction budget" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqualStrings("a.elf", defaults.path);
    try std.testing.expectEqual(@as(?usize, null), defaults.instructions);

    const bounded = try parse(&[_][]const u8{ "emu", "a.elf", "--instructions", "64" });
    try std.testing.expectEqual(@as(?usize, 64), bounded.instructions);

    try std.testing.expectError(error.MissingImage, parse(&[_][]const u8{"emu"}));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--instructions" }));
    try std.testing.expectError(error.UnknownFlag, parse(&[_][]const u8{ "emu", "a.elf", "--nope" }));
}

test "the part defaults to the RA8D2 and is named, never guessed" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqual(Part.ra8d2, defaults.part);

    const npu_part = try parse(&[_][]const u8{ "emu", "a.elf", "--part", "ra8p1" });
    try std.testing.expectEqual(Part.ra8p1, npu_part.part);

    try std.testing.expectError(error.UnknownPart, parse(&[_][]const u8{ "emu", "a.elf", "--part", "ra8m1" }));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--part" }));
}

test "an unwatched run gets the default budget" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqual(mod.budget, options.budgetFor(false));
}

test "a watched run gets the larger budget, because it stops on its counter" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--stop-sym", "g_tick", "5" });
    try std.testing.expectEqual(mod.watched_budget, options.budgetFor(true));
    try std.testing.expect(mod.watched_budget > mod.budget);
}

test "a counter that did not resolve watches nothing, so it keeps the default" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--stop-sym", "g_absent", "5" });
    try std.testing.expectEqual(mod.budget, options.budgetFor(false));
}

test "an asked-for budget wins over either default" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--instructions", "64", "--stop-sym", "g_tick", "5" });
    try std.testing.expectEqual(@as(usize, 64), options.budgetFor(true));
    try std.testing.expectEqual(@as(usize, 64), options.budgetFor(false));
}

test "the Click module is off unless --click fits it" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(!defaults.click);
    const fitted = try parse(&[_][]const u8{ "emu", "a.elf", "--click" });
    try std.testing.expect(fitted.click);
}

test "--cpu picks the CPU, defaulting to Unicorn" {
    const Choice = ra8.core.cpu.choice.Choice;
    try std.testing.expectEqual(Choice.unicorn, (try parse(&[_][]const u8{ "emu", "a.elf" })).cpu);
    try std.testing.expectEqual(Choice.zig, (try parse(&[_][]const u8{ "emu", "a.elf", "--cpu", "zig" })).cpu);
    try std.testing.expectError(error.BadValue, parse(&[_][]const u8{ "emu", "a.elf", "--cpu", "arm" }));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--cpu" }));
}

test "--ns names the Non-Secure companion image, and is off by default" {
    try std.testing.expectEqual(@as(?[]const u8, null), (try parse(&[_][]const u8{ "emu", "a.elf" })).ns_path);
    const options = try parse(&[_][]const u8{ "emu", "s.elf", "--ns", "s_ns.elf" });
    try std.testing.expectEqualStrings("s_ns.elf", options.ns_path.?);
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "s.elf", "--ns" }));
}

test {
    _ = @import("touch_spec_test.zig");
}

test "--cpu-load-from and --cpu-load-to set the load window and turn --cpu-load on" {
    const plain = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(plain.rtosWanted() == null);
    const whole = try parse(&[_][]const u8{ "emu", "a.elf", "--cpu-load" });
    try std.testing.expectEqual(@as(u64, 0), whole.rtosWanted().?.from);
    try std.testing.expectEqual(std.math.maxInt(u64), whole.rtosWanted().?.to);
    const windowed = try parse(&[_][]const u8{ "emu", "a.elf", "--cpu-load-from", "1000", "--cpu-load-to", "0x2000" });
    try std.testing.expect(windowed.cpu_load);
    try std.testing.expectEqual(@as(u64, 1000), windowed.rtosWanted().?.from);
    try std.testing.expectEqual(@as(u64, 0x2000), windowed.rtosWanted().?.to);
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--cpu-load-to" }));
}

test "precise BusFaults are off unless --bus-errors asks for them" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(!defaults.bus_errors);
    const asked = try parse(&[_][]const u8{ "emu", "a.elf", "--bus-errors" });
    try std.testing.expect(asked.bus_errors);
}
