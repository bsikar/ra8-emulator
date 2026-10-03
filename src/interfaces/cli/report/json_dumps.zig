//! The `dumps` object of `--report json` (RA8EMU-381): the `--dump-sym`
//! globals, `--dump-regs` and `--dump-mem` words, the same reads
//! report/dumps.zig and debug/mem_dump.zig print. A symbol the images do
//! not carry or a word the core will not read is null, never a number
//! nothing measured. The sd block and the watch log are RA8EMU-391.
const std = @import("std");
const engine = @import("../../../core/engine.zig");
const elf = @import("../../../core/elf.zig");
const cli = @import("../cli.zig");
const symbols = @import("../../../debug/symbols.zig");
const registers = @import("../../../debug/registers.zig");
const mem_dump = @import("../../../debug/mem_dump.zig");
const place = @import("../../../debug/place.zig");
const report_dumps = @import("dumps.zig");

/// What the dumps read from: the core as the run left it, the image and the
/// flags that asked.
pub const Dumps = struct {
    core: engine.Engine,
    image: elf.Image,
    options: *const cli.Options,
};

/// The `dumps` object, or null when nothing was handed over to read.
pub fn section(j: anytype, found: ?*const Dumps) !void {
    const of = found orelse return j.field("dumps", null);
    try j.open("dumps", '{');
    try globals(j, of);
    try regs(j, of.core, of.options.dump_regs);
    try memory(j, of.core, of.image, of.options.dump_mem, of.options.dump_mem_words);
    try j.close('}');
}

/// One row per `--dump-sym` name, looked up in the `--ns` image too.
fn globals(j: anytype, of: *const Dumps) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var images: [2]elf.Image = .{ of.image, undefined };
    var count: usize = 1;
    if (of.options.dumps().len != 0) {
        if (try report_dumps.nonSecure(arena.allocator(), of.options.*)) |second| {
            images[1] = second;
            count = 2;
        }
    }
    try j.open("symbols", '[');
    for (of.options.dumps()) |name| {
        const address = symbols.addressInAny(images[0..count], name);
        const value: ?u32 = if (address) |at| of.core.readWord(at) catch null else null;
        try j.open(null, '{');
        try j.field("name", name);
        try j.field("address", address);
        try j.field("value", value);
        try j.close('}');
    }
    try j.close(']');
}

fn regs(j: anytype, core: engine.Engine, asked: bool) !void {
    if (!asked) return j.field("registers", null);
    try j.open("registers", '{');
    for (registers.dumped) |named| {
        const value: ?u32 = core.register(named.which) catch null;
        try j.field(named.name, value);
    }
    const sp: ?u32 = core.register(.sp) catch null;
    try j.open("stack", '[');
    for (0..registers.limits.stack_words) |index| {
        const value: ?u32 = if (sp) |base| core.readWord(registers.stackWord(base, index)) catch null else null;
        try j.field(null, value);
    }
    try j.close(']');
    try j.close('}');
}

fn memory(j: anytype, core: engine.Engine, image: elf.Image, spec: ?[]const u8, asked: ?u32) !void {
    const named = spec orelse return j.field("memory", null);
    try j.open("memory", '{');
    try j.field("place", named);
    const at = mem_dump.resolve(core, image, named) catch |err| {
        try j.field("address", null);
        try j.field("error", @errorName(err));
        try j.open("words", '[');
        try j.close(']');
        return j.close('}');
    };
    try j.field("address", at);
    try j.field("error", null);
    try j.open("words", '[');
    for (0..place.words(asked)) |step| {
        const index: u32 = @intCast(step);
        const value: ?u32 = core.readWord(at +% index * 4) catch null;
        try j.field(null, value);
    }
    try j.close(']');
    try j.close('}');
}
