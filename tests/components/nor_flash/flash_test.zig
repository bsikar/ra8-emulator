//! Covers src/components/nor_flash/flash.zig: NOR semantics and the sparse store.
const std = @import("std");
const ra8 = @import("ra8");

const flash = ra8.components.nor_flash;

test "an untouched part reads erased everywhere and holds nothing" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();

    try std.testing.expectEqual(@as(u8, 0xFF), part.byte(0));
    try std.testing.expectEqual(@as(u8, 0xFF), part.byte(flash.part.size - 1));
    try std.testing.expectEqual(@as(u32, 0), part.live());
}

test "a program only clears bits" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();

    try part.program(0x1000, 0x33);
    try std.testing.expectEqual(@as(u8, 0x33), part.byte(0x1000));
    // 0x0F over 0x33 is 0x03: the high nibble stays gone.
    try part.program(0x1000, 0x0F);
    try std.testing.expectEqual(@as(u8, 0x03), part.byte(0x1000));
}

test "a program cannot put a one back" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();

    try part.program(0x2000, 0x00);
    try part.program(0x2000, 0xFF);
    try std.testing.expectEqual(@as(u8, 0x00), part.byte(0x2000));
}

test "only an erase restores the sector" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();

    try part.program(0x4010, 0x00);
    part.erase(0x4FFF);
    try std.testing.expectEqual(@as(u8, 0xFF), part.byte(0x4010));
    try std.testing.expectEqual(@as(u32, 0), part.live());
}

test "an erase reaches its own sector only" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();

    try part.program(0x0FFF, 0x00);
    try part.program(0x1000, 0x00);
    part.erase(0x1234);
    try std.testing.expectEqual(@as(u8, 0x00), part.byte(0x0FFF));
    try std.testing.expectEqual(@as(u8, 0xFF), part.byte(0x1000));
}

test "the store is sparse: a sector is held only once something is in it" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();

    // Programming 0xFF changes nothing, so nothing has to be held for it.
    try part.program(0x8000, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), part.live());
    try part.program(0x8000, 0xF0);
    try std.testing.expectEqual(@as(u32, 1), part.live());
    try part.program(0x8004, 0x0F);
    try std.testing.expectEqual(@as(u32, 1), part.live());
    try part.program(0x9000, 0x0F);
    try std.testing.expectEqual(@as(u32, 2), part.live());
}

test "reads and writes past the part are erased and ignored" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();

    try part.program(flash.part.size, 0x00);
    part.erase(flash.part.size + 0x1000);
    try std.testing.expectEqual(@as(u8, 0xFF), part.byte(flash.part.size));
    try std.testing.expectEqual(@as(u32, 0), part.live());
}

test "reset gives back a fresh part" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();

    try part.program(0x100, 0x00);
    try part.program(0x5_0000, 0x00);
    part.reset();
    try std.testing.expectEqual(@as(u32, 0), part.live());
    try std.testing.expectEqual(@as(u8, 0xFF), part.byte(0x100));
    try std.testing.expectEqual(@as(u8, 0xFF), part.byte(0x5_0000));
}

test "the sector of an address is its 4 KiB block" {
    try std.testing.expectEqual(@as(u32, 0), flash.part.sectorOf(0x0FFF));
    try std.testing.expectEqual(@as(u32, 1), flash.part.sectorOf(0x1000));
    try std.testing.expect(flash.part.holds(flash.part.size - 8, 8));
    try std.testing.expect(!flash.part.holds(flash.part.size - 7, 8));
}

test "configured capacity changes bounds and JEDEC density together" {
    var memory = flash.Flash.init(std.testing.allocator);
    defer memory.deinit();
    try memory.resize(1024 * 1024);
    try std.testing.expect(memory.holds(1024 * 1024 - 1, 1));
    try std.testing.expect(!memory.holds(1024 * 1024, 1));
    try std.testing.expectEqual(@as(u8, 20), memory.jedecId()[2]);
}

test "the page of an address is its 256-byte block" {
    try std.testing.expectEqual(@as(u32, 0x1000), flash.part.pageOf(0x1000));
    try std.testing.expectEqual(@as(u32, 0x1000), flash.part.pageOf(0x10FF));
    try std.testing.expectEqual(@as(u32, 0x1100), flash.part.pageOf(0x1100));
}

test "a program step wraps to the start of its own page" {
    // Four bytes from 0x10FE: two at the top of the page, two back at 0x1000.
    try std.testing.expectEqual(@as(u32, 0x10FE), flash.part.programStep(0x10FE, 0));
    try std.testing.expectEqual(@as(u32, 0x10FF), flash.part.programStep(0x10FE, 1));
    try std.testing.expectEqual(@as(u32, 0x1000), flash.part.programStep(0x10FE, 2));
    try std.testing.expectEqual(@as(u32, 0x1001), flash.part.programStep(0x10FE, 3));
    // One that fits walks straight up.
    try std.testing.expectEqual(@as(u32, 0x1003), flash.part.programStep(0x1000, 3));
}

test "a program crosses its page only when it runs past the end" {
    try std.testing.expect(!flash.part.crossesPage(0x1000, 8));
    try std.testing.expect(!flash.part.crossesPage(0x10F8, 8));
    try std.testing.expect(flash.part.crossesPage(0x10F9, 8));
    try std.testing.expect(!flash.part.crossesPage(0x10FF, 0));
}

const observer = ra8.chip.core.cpu.memory.observer;

/// A recording observer the tests attach to the part (H3).
const Hook = struct {
    writes: [8]W = undefined,
    write_count: usize = 0,
    barriers: [4]What = undefined,
    barrier_count: usize = 0,

    const W = struct { offset: u64 = 0, pre: [0x1000]u8 = undefined, len: usize = 0 };
    const What = enum { reset, install, resize };

    const vtable = observer.Observer.VTable{ .bytes = bytes, .barrier = barrier };

    fn bytes(ctx: *anyopaque, write: observer.Write) void {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        const w = &self.writes[self.write_count];
        w.offset = write.offset;
        w.len = write.pre.len;
        @memcpy(w.pre[0..write.pre.len], write.pre);
        self.write_count += 1;
    }

    fn barrier(ctx: *anyopaque, event: observer.Barrier) void {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        switch (event) {
            .component => |c| {
                self.barriers[self.barrier_count] = switch (c.what) {
                    .reset => .reset,
                    .install => .install,
                    .resize => .resize,
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

test "the trail hears every byte a program clears" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();
    try part.resize(0x4000);
    var hook = Hook{};
    part.obs = hook.obs();

    try part.program(0x1000, 0x33);
    try std.testing.expectEqual(@as(usize, 1), hook.write_count);
    try std.testing.expectEqual(@as(u64, 0x1000), hook.writes[0].offset);
    try std.testing.expectEqual(@as(usize, 1), hook.writes[0].len);
    try std.testing.expectEqual(@as(u8, 0xFF), hook.writes[0].pre[0]);
    try std.testing.expectEqual(@as(u8, 0x33), part.byte(0x1000));

    // A program that changes nothing invents no record.
    try part.program(0x1000, 0x33);
    try std.testing.expectEqual(@as(usize, 1), hook.write_count);
}

test "an erase records the whole sector it wipes, erased bytes included" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();
    try part.resize(0x4000);
    var hook = Hook{};
    part.obs = hook.obs();

    try part.program(0x2001, 0x0F);
    try part.program(0x2FFF, 0xF0);
    hook.write_count = 0;

    part.erase(0x2000);
    try std.testing.expectEqual(@as(usize, 1), hook.write_count);
    try std.testing.expectEqual(@as(u64, 0x2000), hook.writes[0].offset);
    try std.testing.expectEqual(@as(usize, 0x1000), hook.writes[0].len);
    try std.testing.expectEqual(@as(u8, 0xFF), hook.writes[0].pre[0]);
    try std.testing.expectEqual(@as(u8, 0x0F), hook.writes[0].pre[1]);
    try std.testing.expectEqual(@as(u8, 0xF0), hook.writes[0].pre[0xFFF]);
    try std.testing.expectEqual(@as(u8, 0xFF), part.byte(0x2001));
}

test "a reset, a resize and an install raise barriers and keep the observer" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();
    try part.resize(0x4000);
    var hook = Hook{};
    part.obs = hook.obs();

    part.reset();
    try std.testing.expectEqual(@as(usize, 1), hook.barrier_count);
    try std.testing.expectEqual(Hook.What.reset, hook.barriers[0]);

    try part.resize(0x8000);
    try std.testing.expectEqual(@as(usize, 2), hook.barrier_count);
    try std.testing.expectEqual(Hook.What.resize, hook.barriers[1]);

    var staged = flash.Flash.init(std.testing.allocator);
    try staged.resize(0x4000);
    flash.snapshot.install(&part, staged);
    try std.testing.expectEqual(@as(usize, 3), hook.barrier_count);
    try std.testing.expectEqual(Hook.What.install, hook.barriers[2]);
    try std.testing.expect(part.obs != null);
}

test "a raw restore lands past NOR semantics and records nothing" {
    var part = flash.Flash.init(std.testing.allocator);
    defer part.deinit();
    try part.resize(0x4000);
    var hook = Hook{};
    part.obs = hook.obs();

    try part.program(0x0, 0x00);
    const count = hook.write_count;

    part.rawWrite(0x0, &.{0xFF});
    try std.testing.expectEqual(count, hook.write_count);
    try std.testing.expectEqual(@as(u8, 0xFF), part.byte(0x0));
    try std.testing.expectEqual(@as(u32, 1), part.live());
}
