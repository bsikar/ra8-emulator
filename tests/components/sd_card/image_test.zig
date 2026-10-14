//! Covers src/components/sd_card/image.zig.
const std = @import("std");
const io = std.testing.io;
const image = @import("ra8").components.sd_card.image;
const disk_file = @import("ra8").host.disk_file;

fn unit() image.Image {
    return image.Image.init(std.testing.allocator);
}

test "a fresh card holds nothing and reads back zeros" {
    var img = unit();
    defer img.deinit();
    var block: image.Block = undefined;
    try std.testing.expect(img.read(7, &block));
    try std.testing.expectEqual(@as(usize, 0), img.held());
    for (block) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "a written block comes back and is held" {
    var img = unit();
    defer img.deinit();
    var out: image.Block = @splat(0xA5);
    try std.testing.expect(img.write(3, &out));
    try std.testing.expectEqual(@as(usize, 1), img.held());
    var back: image.Block = undefined;
    try std.testing.expect(img.read(3, &back));
    try std.testing.expectEqualSlices(u8, &out, &back);
}

test "a block past the end of the card is not a block" {
    var img = unit();
    defer img.deinit();
    const past = image.geometry.default_capacity_blocks;
    var block: image.Block = @splat(1);
    try std.testing.expect(!img.write(past, &block));
    try std.testing.expect(!img.read(past, &block));
    try std.testing.expect(img.inRange(past - 1));
}

test "an erase gives the blocks back instead of filling them with zeros" {
    var img = unit();
    defer img.deinit();
    const filled: image.Block = @splat(0xFF);
    try std.testing.expect(img.write(10, &filled));
    try std.testing.expect(img.write(11, &filled));
    try std.testing.expect(img.write(20, &filled));
    try std.testing.expectEqual(@as(u32, 2), img.zero(10, 11));
    try std.testing.expectEqual(@as(usize, 1), img.held());
    var back: image.Block = undefined;
    try std.testing.expect(img.read(10, &back));
    for (back) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "an erase of blocks nobody wrote clears nothing" {
    var img = unit();
    defer img.deinit();
    try std.testing.expectEqual(@as(u32, 0), img.zero(0, 31));
}

test "a blank card takes another size, and a card holding data does not" {
    var img = unit();
    defer img.deinit();
    try std.testing.expect(img.resize(128 * 1024));
    try std.testing.expectEqual(@as(u32, 128 * 1024), img.capacity_blocks);
    try std.testing.expect(img.inRange(100 * 1024));
    try std.testing.expectEqual(@as(u32, 127), img.csize());

    try std.testing.expect(!img.resize(0));
    try std.testing.expect(!img.resize(1500));

    const block: image.Block = @splat(7);
    try std.testing.expect(img.write(1, &block));
    try std.testing.expect(!img.resize(64 * 1024));
    try std.testing.expectEqual(@as(u32, 128 * 1024), img.capacity_blocks);
}

test "a fresh card is 64 MiB and its CSD reports that capacity" {
    var blank = unit();
    defer blank.deinit();
    try std.testing.expectEqual(@as(u32, 128 * 1024), blank.capacity_blocks);
    try std.testing.expectEqual(@as(u32, 127), blank.csize());
    try std.testing.expectEqual(
        image.geometry.default_capacity_blocks / image.geometry.csize_unit - 1,
        blank.csize(),
    );
}

test "a rewrite replaces the block instead of holding a second one" {
    var img = unit();
    defer img.deinit();
    const first: image.Block = @splat(1);
    const second: image.Block = @splat(2);
    try std.testing.expect(img.write(5, &first));
    try std.testing.expect(img.write(5, &second));
    try std.testing.expectEqual(@as(usize, 1), img.held());
    var back: image.Block = undefined;
    try std.testing.expect(img.read(5, &back));
    try std.testing.expectEqual(@as(u8, 2), back[0]);
}

test "release hands every block back" {
    var img = unit();
    defer img.deinit();
    const filled: image.Block = @splat(9);
    try std.testing.expect(img.write(1, &filled));
    img.release();
    try std.testing.expectEqual(@as(usize, 0), img.held());
}

test "a raw image attaches at its stated capacity and keeps zero blocks sparse" {
    var img = unit();
    defer img.deinit();
    const bytes = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    bytes[5 * image.geometry.block_bytes] = 0xA5;
    try img.loadBytes(bytes);
    try std.testing.expectEqual(@as(u32, 1024), img.capacity_blocks);
    try std.testing.expectEqual(@as(u32, 0), img.csize());
    try std.testing.expectEqual(@as(usize, 1), img.held());
    var loaded: image.Block = undefined;
    try std.testing.expect(img.read(5, &loaded));
    try std.testing.expectEqual(@as(u8, 0xA5), loaded[0]);
    try std.testing.expect(img.read(6, &loaded));
    try std.testing.expectEqual(@as(u8, 0), loaded[0]);
}

test "a raw image must fit the exact SDHC capacity field" {
    var img = unit();
    defer img.deinit();
    try std.testing.expectError(error.BadImageSize, img.loadBytes(&.{}));
    const bytes = try std.testing.allocator.alloc(u8, 512 * 1024 + 1);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.BadImageSize, img.loadBytes(bytes));
}

/// A one-unit (512 KiB) raw image whose block n starts with byte n + 1 for
/// the first few blocks, the rest zeros.
fn patterned(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try allocator.alloc(u8, image.geometry.csize_unit * image.geometry.block_bytes);
    @memset(bytes, 0);
    for (0..4) |n| bytes[n * image.geometry.block_bytes] = @intCast(n + 1);
    return bytes;
}

test "write back: a written block round-trips through the image file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try patterned(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "card.img", .data = bytes });
    var img = unit();
    defer img.deinit();
    try img.loadBytes(bytes);
    const written: image.Block = @splat(0xA5);
    try std.testing.expect(img.write(9, &written));
    try disk_file.replace(io, tmp.dir, "card.img", &img);
    const back = try tmp.dir.readFileAlloc(io, "card.img", std.testing.allocator, .limited(bytes.len + 1));
    defer std.testing.allocator.free(back);
    try std.testing.expectEqual(bytes.len, back.len);
    try std.testing.expectEqualSlices(u8, &written, back[9 * 512 .. 10 * 512]);
    try std.testing.expectEqualSlices(u8, bytes[0 .. 9 * 512], back[0 .. 9 * 512]);
}

test "write back: an unchanged card leaves the image byte-identical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try patterned(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "card.img", .data = bytes });
    var img = unit();
    defer img.deinit();
    try img.loadBytes(bytes);
    try disk_file.replace(io, tmp.dir, "card.img", &img);
    const back = try tmp.dir.readFileAlloc(io, "card.img", std.testing.allocator, .limited(bytes.len + 1));
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualSlices(u8, bytes, back);
}

/// A reader that denies delete-sharing forces Windows replacement to fail.
fn preventReplace(dir: std.Io.Dir) !std.os.windows.HANDLE {
    const win32 = @import("ra8").host.win32;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try dir.realPathFile(io, "ro/card.img", &path_buf)];
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(wide);
    const handle = win32.CreateFileW(wide, 0x8000_0000, 0x3, null, 3, 0, null);
    if (handle == win32.invalid_handle) return error.OpenFailed;
    return handle;
}

test "write back: a write that fails leaves the original image intact" {
    if (@import("builtin").os.tag == .linux and std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try patterned(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try tmp.dir.createDir(io, "ro", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "ro/card.img", .data = bytes });
    var img = unit();
    defer img.deinit();
    try img.loadBytes(bytes);
    const written: image.Block = @splat(0x5A);
    try std.testing.expect(img.write(3, &written));
    var ro = try tmp.dir.openDir(io, "ro", .{ .iterate = true });
    defer ro.close(io);
    const windows = @import("builtin").os.tag == .windows;
    const held: ?std.os.windows.HANDLE = if (windows) try preventReplace(tmp.dir) else null;
    defer if (held) |handle| @import("ra8").host.read.close(handle);
    if (!windows) try ro.setPermissions(io, .fromMode(0o555));
    defer if (!windows) ro.setPermissions(io, .fromMode(0o755)) catch {};
    // Zig 0.17 maps NTSTATUS SHARING_VIOLATION during rename to Unexpected.
    const refusal = if (windows) error.Unexpected else error.AccessDenied;
    try std.testing.expectError(refusal, disk_file.replace(io, tmp.dir, "ro/card.img", &img));
    const back = try tmp.dir.readFileAlloc(io, "ro/card.img", std.testing.allocator, .limited(bytes.len + 1));
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualSlices(u8, bytes, back);
}

const observer = @import("ra8").chip.core.cpu.memory.observer;

/// A recording observer the tests attach to an image (H6).
const Hook = struct {
    writes: [4]W = undefined,
    write_count: usize = 0,
    barriers: [4]What = undefined,
    barrier_count: usize = 0,

    const W = struct { offset: u64 = 0, pre: [512]u8 = undefined };
    const What = enum { install, resize, release };

    const vtable = observer.Observer.VTable{ .bytes = bytes, .barrier = barrier };

    fn bytes(ctx: *anyopaque, write: observer.Write) void {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        self.writes[self.write_count] = .{
            .offset = write.offset,
            .pre = write.pre[0..512].*,
        };
        self.write_count += 1;
    }

    fn barrier(ctx: *anyopaque, event: observer.Barrier) void {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        switch (event) {
            .component => |c| {
                self.barriers[self.barrier_count] = switch (c.what) {
                    .install => .install,
                    .resize => .resize,
                    .release => .release,
                    else => unreachable,
                };
                self.barrier_count += 1;
            },
            else => unreachable,
        }
    }

    fn obs(self: *Hook) observer.Observer {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

test "a write over a held block records the block it replaces" {
    var img = unit();
    defer img.deinit();
    var hook = Hook{};
    img.obs = hook.obs();

    var first: image.Block = @splat(0x11);
    try std.testing.expect(img.write(5, &first));
    var second: image.Block = @splat(0x22);
    try std.testing.expect(img.write(5, &second));
    try std.testing.expectEqual(@as(usize, 2), hook.write_count);
    try std.testing.expectEqual(@as(u64, 5 * 512), hook.writes[1].offset);
    try std.testing.expectEqual(@as(u8, 0x11), hook.writes[1].pre[0]);
}

test "a real change onto an absent block records zeros; no change invents nothing" {
    var img = unit();
    defer img.deinit();
    var hook = Hook{};
    img.obs = hook.obs();

    // Data over an absent block: the zeros it replaces are the record.
    var data: image.Block = @splat(0x33);
    try std.testing.expect(img.write(9, &data));
    try std.testing.expectEqual(@as(usize, 1), hook.write_count);
    try std.testing.expectEqual(@as(u8, 0), hook.writes[0].pre[0]);

    // A zero block over an absent one leaves the card reading the same.
    var zeros: image.Block = @splat(0);
    try std.testing.expect(img.write(10, &zeros));
    try std.testing.expectEqual(@as(usize, 1), hook.write_count);

    // Identical bytes over a held block change nothing.
    try std.testing.expect(img.write(9, &data));
    try std.testing.expectEqual(@as(usize, 1), hook.write_count);
}

test "a zero clears records what was there before it went" {
    var img = unit();
    defer img.deinit();
    var hook = Hook{};
    img.obs = hook.obs();

    var data: image.Block = @splat(0x44);
    try std.testing.expect(img.write(12, &data));
    try std.testing.expect(img.write(13, &data));
    hook.write_count = 0;

    try std.testing.expectEqual(@as(u32, 2), img.zero(12, 13));
    try std.testing.expectEqual(@as(usize, 2), hook.write_count);
    try std.testing.expectEqual(@as(u64, 12 * 512), hook.writes[0].offset);
    try std.testing.expectEqual(@as(u64, 13 * 512), hook.writes[1].offset);
    try std.testing.expectEqual(@as(u8, 0x44), hook.writes[0].pre[0]);
    try std.testing.expectEqual(@as(usize, 0), img.held());
}

test "a whole-image load and a release raise their barriers" {
    var img = unit();
    defer img.deinit();
    var hook = Hook{};
    img.obs = hook.obs();

    // A whole-image load is one install barrier, not a trail of writes.
    const bytes = try patterned(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try img.loadBytes(bytes);
    try std.testing.expectEqual(@as(usize, 1), hook.barrier_count);
    try std.testing.expectEqual(Hook.What.install, hook.barriers[0]);
    try std.testing.expectEqual(@as(usize, 0), hook.write_count);
    try std.testing.expectEqual(@as(usize, 4), img.held());

    img.release();
    try std.testing.expectEqual(@as(usize, 2), hook.barrier_count);
    try std.testing.expectEqual(Hook.What.release, hook.barriers[1]);
    try std.testing.expectEqual(@as(usize, 0), img.held());
}

test "a resize the card takes raises a barrier" {
    var img = unit();
    defer img.deinit();
    var hook = Hook{};
    img.obs = hook.obs();

    try std.testing.expect(img.resize(256 * 1024));
    try std.testing.expectEqual(@as(usize, 1), hook.barrier_count);
    try std.testing.expectEqual(Hook.What.resize, hook.barriers[0]);
    // Same size again: no change, no barrier.
    try std.testing.expect(img.resize(256 * 1024));
    try std.testing.expectEqual(@as(usize, 1), hook.barrier_count);
}
