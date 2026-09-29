//! The watched place: what a store records, what the list keeps, and the
//! spellings that watch nothing at all.
const std = @import("std");
const ra8 = @import("ra8");
const watchpoint = ra8.core.watchpoint;

test "a store records its pc, its value and its width" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    watched.record(0x0200_FEDC, 0x0200_1235, 0x2204_00A0, 1, 5);
    try std.testing.expectEqual(@as(usize, 1), watched.seen);
    const store = watched.listed()[0];
    try std.testing.expectEqual(@as(u32, 0x0200_FEDC), store.pc);
    try std.testing.expectEqual(@as(u32, 5), store.value);
    try std.testing.expectEqual(@as(u8, 1), store.width);
    try std.testing.expectEqual(@as(u8, 0), store.offset);
    try std.testing.expectEqual(@as(u32, 0x0200_1235), store.lr);
}

test "a store inside the word records which byte it started at" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    watched.record(0x0200_FEDC, 0x0200_1235, 0x2204_00A2, 2, 0xBEEF);
    try std.testing.expectEqual(@as(u8, 2), watched.listed()[0].offset);
}

test "stores come back oldest first" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    watched.record(0x0200_1000, 0x0200_1235, 0x2204_00A0, 4, 1);
    watched.record(0x0200_2000, 0x0200_1235, 0x2204_00A0, 4, 2);
    const kept = watched.listed();
    try std.testing.expectEqual(@as(u32, 1), kept[0].value);
    try std.testing.expectEqual(@as(u32, 2), kept[1].value);
}

test "a value written past the list is counted and dropped" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    const written = watchpoint.limits.listed + 5;
    for (0..written) |index| {
        watched.record(0x0200_1000, 0x0200_1235, 0x2204_00A0, 4, @intCast(index));
    }
    try std.testing.expectEqual(written, watched.seen);
    try std.testing.expectEqual(watchpoint.limits.listed, watched.listed().len);
    // The list keeps the first stores, which are the ones that say how the
    // value got where it is.
    try std.testing.expectEqual(@as(u32, 0), watched.listed()[0].value);
}

test "a place nothing wrote to keeps an empty list" {
    const watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    try std.testing.expectEqual(@as(usize, 0), watched.seen);
    try std.testing.expectEqual(@as(usize, 0), watched.listed().len);
}

test "the window is a word wide" {
    const watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    try std.testing.expectEqual(@as(u32, 0x2204_00A3), watched.end());
}

test "nothing named is nothing watched" {
    var buffer: [@sizeOf(ra8.core.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.core.elf.Header =
        std.mem.bytesAsValue(ra8.core.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.core.elf.em_arm;
    const image = try ra8.core.elf.Image.init(&buffer);
    try std.testing.expect(watchpoint.resolve(image, null) == null);
}

test "a literal place resolves without a symbol table" {
    var buffer: [@sizeOf(ra8.core.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.core.elf.Header =
        std.mem.bytesAsValue(ra8.core.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.core.elf.em_arm;
    const image = try ra8.core.elf.Image.init(&buffer);
    const watched = watchpoint.resolve(image, "0x220400A0") orelse return error.NotResolved;
    try std.testing.expectEqual(@as(u32, 0x2204_00A0), watched.address);
}

test "a name the image does not carry watches nothing" {
    var buffer: [@sizeOf(ra8.core.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.core.elf.Header =
        std.mem.bytesAsValue(ra8.core.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.core.elf.em_arm;
    const image = try ra8.core.elf.Image.init(&buffer);
    try std.testing.expect(watchpoint.resolve(image, "g_missing") == null);
}

test "a dereferencing place watches nothing" {
    var buffer: [@sizeOf(ra8.core.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.core.elf.Header =
        std.mem.bytesAsValue(ra8.core.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.core.elf.em_arm;
    const image = try ra8.core.elf.Image.init(&buffer);
    try std.testing.expect(watchpoint.resolve(image, "@0x220400A0+0x10") == null);
}

test "an offset is applied to a literal base" {
    var buffer: [@sizeOf(ra8.core.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.core.elf.Header =
        std.mem.bytesAsValue(ra8.core.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.core.elf.em_arm;
    const image = try ra8.core.elf.Image.init(&buffer);
    const watched = watchpoint.resolve(image, "0x22040000+0xA0") orelse return error.NotResolved;
    try std.testing.expectEqual(@as(u32, 0x2204_00A0), watched.address);
}

test "a watch nothing wrote to still prints its place" {
    var buffer: [@sizeOf(ra8.core.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.core.elf.Header =
        std.mem.bytesAsValue(ra8.core.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.core.elf.em_arm;
    const image = try ra8.core.elf.Image.init(&buffer);
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    try watchpoint.print(out.writer(), image, "g_eoh_err", watched);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "0 store(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "g_eoh_err @0x220400A0") != null);
}

test "no watch prints nothing at all" {
    var buffer: [@sizeOf(ra8.core.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.core.elf.Header =
        std.mem.bytesAsValue(ra8.core.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.core.elf.em_arm;
    const image = try ra8.core.elf.Image.init(&buffer);
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try watchpoint.print(out.writer(), image, null, null);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
