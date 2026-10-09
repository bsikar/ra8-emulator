//! `ra8_emulator --map <elf>`: the memory map of a firmware image, printed
//! like the summary at the end of a linker map, then exit.
//!
//! One block per linker region (name, range, used/total, percent) with the
//! sections that run there underneath: name, run address, load address when
//! it differs, size. A section stored apart from where it runs (.data) also
//! shows under the region holding its stored copy, so each block's lines add
//! up to its used figure. Then the stack reservation, then any section that
//! fits no region. The numbers are region_map.zig's; this file only lays
//! them out.
const std = @import("std");
const elf = @import("../../board/loader/elf.zig");
const sections = @import("../../session/sections.zig");
const region_map = @import("../../session/region_map.zig");

const usage = "usage: ra8_emulator --map <firmware.elf>\n";

/// The whole command: argv[1] is "--map", argv[2] the image.
pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    if (argv.len != 3) {
        std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
        return 2;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, argv[2], allocator, .limited(1 << 30)) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ argv[2], @errorName(err) });
        return 1;
    };
    const image = elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ argv[2], @errorName(err) });
        return 1;
    };
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try render(&stdout.interface, image, &region_map.ek_ra8d2);
    try stdout.interface.flush();
    return 0;
}

/// The map of `image` over `regions`, as text.
pub fn render(writer: anytype, image: elf.Image, regions: []const region_map.Region) !void {
    const map = try region_map.build(image, regions);
    for (regions, 0..) |region, index| {
        try regionLine(writer, region, map.used[index]);
        try sectionsIn(writer, image, regions, index);
    }
    try stackLine(writer, map);
    if (map.outside != 0) {
        try writer.print("outside every region: {d} sections, {d} bytes\n", .{ map.outside, map.outside_bytes });
        try sectionsIn(writer, image, regions, null);
    }
}

fn regionLine(writer: anytype, region: region_map.Region, used: u64) !void {
    const last = @as(u64, region.base) + region.size - 1;
    const tenths = if (region.size == 0) 0 else used * 1000 / region.size;
    try writer.print("{s: <8} 0x{x:0>8}-0x{x:0>8}  {d: >8} / {d: >8} bytes  {d}.{d}%\n", .{
        region.name, region.base, last, used, region.size, tenths / 10, tenths % 10,
    });
}

/// The sections placed in region `wanted` (null: in none), each where it
/// runs and, for a stored copy, where it is stored.
fn sectionsIn(writer: anytype, image: elf.Image, regions: []const region_map.Region, wanted: ?usize) !void {
    var index: u16 = 0;
    while (index < image.header().e_shnum) : (index += 1) {
        const found = sections.read(image, index) orelse continue;
        if (found.size == 0) continue;
        if (region_map.regionAt(regions, found.vma, found.size) == wanted) try runLine(writer, found);
        if (!found.stored() or found.lma == found.vma) continue;
        if (region_map.regionAt(regions, found.lma, found.size) == wanted) try storedLine(writer, found);
    }
}

fn runLine(writer: anytype, found: sections.Section) !void {
    if (found.stored() and found.lma != found.vma) {
        try writer.print("  {s: <30} run  0x{x:0>8}  load 0x{x:0>8}  {d: >8}\n", .{ found.name, found.vma, found.lma, found.size });
    } else {
        try writer.print("  {s: <30} run  0x{x:0>8}                   {d: >8}\n", .{ found.name, found.vma, found.size });
    }
}

fn storedLine(writer: anytype, found: sections.Section) !void {
    try writer.print("  {s: <30} load 0x{x:0>8}  (runs at 0x{x:0>8})  {d: >8}\n", .{ found.name, found.lma, found.vma, found.size });
}

fn stackLine(writer: anytype, map: region_map.Map) !void {
    const stack = map.stack orelse return writer.writeAll("stack    not found (no g_ra8_ls_stack_top / g_ra8_ls_stack_size)\n");
    const where = if (stack.region) |index| map.regions[index].name else "no region";
    try writer.print("stack    0x{x:0>8}-0x{x:0>8}  {d: >8} bytes in {s}\n", .{
        stack.base, stack.base +% stack.size -% 1, stack.size, where,
    });
}
