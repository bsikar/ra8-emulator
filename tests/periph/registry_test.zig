//! Tests for src/periph/registry.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.periph.registry;

const Block = mod.Block;
const Bus = mod.Bus;
const Error = mod.Error;
const base = mod.base;
const ns_base = mod.ns_base;
const size = mod.size;

const TestBlock = struct {
    hits: u32 = 0,
    last: u32 = 0,

    fn read(context: *anyopaque, address: u32, width: u3) u32 {
        _ = width;
        const self: *TestBlock = @ptrCast(@alignCast(context));
        self.hits += 1;
        return address;
    }

    fn write(context: *anyopaque, address: u32, width: u3, value: u32) void {
        _ = address;
        _ = width;
        const self: *TestBlock = @ptrCast(@alignCast(context));
        self.last = value;
    }

    fn descriptor(self: *TestBlock, at: u32, span: u32) Block {
        return .{
            .name = "test",
            .base = at,
            .size = span,
            .context = self,
            .readFn = read,
            .writeFn = write,
        };
    }
};
test "an unwritten register alternates so a ready-bit poll completes" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    const status = base + 0x1234;
    try std.testing.expectEqual(@as(u32, 0), bus.read(status, 4));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), bus.read(status, 4));
    try std.testing.expectEqual(@as(u32, 0), bus.read(status, 4));
}

test "a written register reads back, masked to the access width" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    const control = base + 0x2000;
    bus.write(control, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), bus.read(control, 4));
    try std.testing.expectEqual(@as(u32, 0xEF), bus.read(control, 1));
    bus.write(control, 2, 0xFFFF_1234);
    try std.testing.expectEqual(@as(u32, 0x1234), bus.read(control, 4));
}

test "the Non-secure alias and the Secure window are one model" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    bus.write(base + 0x40, 4, 0xA5A5_0001);
    try std.testing.expectEqual(@as(u32, 0xA5A5_0001), bus.read(ns_base + 0x40, 4));
    try std.testing.expectEqual(@as(u32, 1), bus.unmodelledAddresses());
}

test "a registered block answers for its own range and nothing else" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var model = TestBlock{};
    try bus.add(model.descriptor(base + 0x8000, 0x1000));

    try std.testing.expectEqual(base + 0x8010, bus.read(base + 0x8010, 4));
    try std.testing.expectEqual(@as(u32, 1), model.hits);
    bus.write(ns_base + 0x8010, 4, 0x55);
    try std.testing.expectEqual(@as(u32, 0x55), model.last);

    _ = bus.read(base + 0x9000, 4);
    try std.testing.expectEqual(@as(u32, 1), model.hits);
    try std.testing.expectEqual(@as(u32, 2), bus.counters.modelled);
}

test "blocks are disjoint and inside the window" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var first = TestBlock{};
    var second = TestBlock{};
    try bus.add(first.descriptor(base + 0x8000, 0x1000));
    try std.testing.expectError(Error.OverlappingBlock, bus.add(second.descriptor(base + 0x8800, 0x1000)));
    try std.testing.expectError(Error.OutsideWindow, bus.add(second.descriptor(0x2000_0000, 0x1000)));
}
