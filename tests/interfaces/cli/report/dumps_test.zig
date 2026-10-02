//! Covers src/interfaces/cli/report/dumps.zig dumpSymbols: the `--dump-sym`
//! line a memory-probe verdict reads, printed the same on either backend.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const elf = ra8.core.elf;
const cli = ra8.core.cli;
const report_dumps = ra8.board.report_dumps;
const Builder = @import("../../../debug/symbol_image.zig").Builder;

fn dumped(core: engine.Engine, image: elf.Image, names: []const []const u8, into: []u8) ![]const u8 {
    var options: cli.Options = .{ .path = "probe.elf" };
    for (names, 0..) |name, index| options.dump[index] = name;
    options.dump_count = names.len;
    var stream = std.io.fixedBufferStream(into);
    try report_dumps.dumpSymbols(stream.writer(), core, image, options);
    return stream.getWritten();
}

test "a dumped global prints its address and value, a missing one says so" {
    var core = try engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try core.writeWord(0x2200_0100, 216662);
    var buffer: [1024]u8 = undefined;
    const image = try elf.Image.init(Builder.build(&buffer, &.{"g_alive"}, &.{0x2200_0100}));
    var out: [256]u8 = undefined;
    const text = try dumped(core, image, &.{ "g_alive", "g_missing" }, &out);
    try std.testing.expectEqualStrings(
        "  dump-sym      : g_alive @0x22000100 = 216662 (0x00034E56)\n" ++
            "  dump-sym      : g_missing <unresolved>\n",
        text,
    );
}

test "no dump asked for prints nothing" {
    var core = try engine.Engine.open();
    defer core.close();
    var buffer: [1024]u8 = undefined;
    const image = try elf.Image.init(Builder.build(&buffer, &.{"g_alive"}, &.{0x2200_0100}));
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try dumped(core, image, &.{}, &out));
}
