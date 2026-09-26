//! Covers src/periph/xspi_flash.zig: NOR semantics and the sparse store.
const std = @import("std");
const ra8 = @import("ra8");

const flash = ra8.periph.xspi_flash;

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
