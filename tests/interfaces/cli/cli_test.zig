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

test "--console streams finished SCI lines when requested" {
    try std.testing.expect(!(try parse(&[_][]const u8{ "emu", "a.elf" })).console);
    try std.testing.expect((try parse(&[_][]const u8{ "emu", "a.elf", "--console" })).console);
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

test "--sd selects a raw card image" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--sd", "card.img" });
    try std.testing.expectEqualStrings("card.img", options.sd_path.?);
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--sd" }));
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
    _ = @import("png_test.zig");
    _ = @import("frame_out_test.zig");
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

test "precise BusFaults are on unless --no-bus-errors turns them off" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(defaults.bus_errors);
    const asked = try parse(&[_][]const u8{ "emu", "a.elf", "--bus-errors" });
    try std.testing.expect(asked.bus_errors);
    const off = try parse(&[_][]const u8{ "emu", "a.elf", "--no-bus-errors" });
    try std.testing.expect(!off.bus_errors);
}

test "profile prints counts and folded profile takes an output path" {
    const cli = @import("ra8").core.cli;
    const asked = try cli.parse(&[_][]const u8{ "emu", "a.elf", "--profile" });
    try std.testing.expect(asked.profile);
    try std.testing.expectEqual(@as(?[]const u8, null), asked.profile_folded);
    const folded = try cli.parse(&[_][]const u8{ "emu", "a.elf", "--profile-folded", "out.folded" });
    try std.testing.expect(folded.profile);
    try std.testing.expectEqualStrings("out.folded", folded.profile_folded.?);
    try std.testing.expectError(error.MissingValue, cli.parse(&[_][]const u8{ "emu", "a.elf", "--profile-folded" }));
}

test "--usb-loop cables the two USB jacks together when requested" {
    try std.testing.expect(!(try parse(&[_][]const u8{ "emu", "a.elf" })).usb_loop);
    try std.testing.expect((try parse(&[_][]const u8{ "emu", "a.elf", "--usb-loop" })).usb_loop);
}

test "--trace-rtos-out takes a path and turns the trace on" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--trace-rtos-out", "run.trace" });
    try std.testing.expect(options.trace_rtos);
    try std.testing.expectEqualStrings("run.trace", options.trace_rtos_out.?);
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--trace-rtos-out" }));
}

test "--report takes text or json and refuses anything else" {
    const plain = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(!plain.report_json);
    const as_json = try parse(&[_][]const u8{ "emu", "a.elf", "--report", "json" });
    try std.testing.expect(as_json.report_json);
    const as_text = try parse(&[_][]const u8{ "emu", "a.elf", "--report", "json", "--report", "text" });
    try std.testing.expect(!as_text.report_json);
    try std.testing.expectError(error.BadValue, parse(&[_][]const u8{ "emu", "a.elf", "--report", "yaml" }));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--report" }));
}
