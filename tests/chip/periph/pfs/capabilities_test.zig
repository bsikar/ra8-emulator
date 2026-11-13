const std = @import("std");
const caps = @import("ra8").chip.periph.pfs.capabilities;

test "the BGA289 GPIO superset has 208 inputs and three input-only pads" {
    var present: usize = 0;
    var outputs: usize = 0;
    var irqs: usize = 0;
    for (0..15) |port| {
        for (0..16) |pin| {
            const pad = caps.get(@intCast(port), @intCast(pin));
            if (!pad.present) continue;
            present += 1;
            outputs += @intFromBool(pad.output);
            irqs += @intFromBool(pad.irq != null);
            try std.testing.expect(pad.input);
            try std.testing.expect(pad.supportsFunction(0));
        }
    }
    try std.testing.expectEqual(@as(usize, 208), present);
    try std.testing.expectEqual(@as(usize, 205), outputs);
    try std.testing.expectEqual(@as(usize, 207), irqs);
    for ([_]u32{ 0, 14, 15 }) |pin| try std.testing.expect(!caps.get(2, pin).output);
}

test "pad lookup rejects unbonded and overflowing coordinates" {
    const coordinates = [_][2]u32{ .{ 11, 8 }, .{ 13, 8 }, .{ 14, 0 }, .{ 0, 16 }, .{ 0xFFFF_FFFF, 0 }, .{ 0, 0xFFFF_FFFF } };
    for (coordinates) |at| {
        const pad = caps.get(at[0], at[1]);
        try std.testing.expect(!pad.present);
        try std.testing.expect(!pad.input and !pad.output and !pad.analog);
        try std.testing.expectEqual(@as(?u5, null), pad.irq);
        try std.testing.expectEqual(@as(u32, 0), pad.sanitize(0xFFFF_FFFF));
        try std.testing.expect(!pad.supportsFunction(0));
    }
}

test "known IRQ channels include switches clocks and the NMI-only pad" {
    try std.testing.expectEqual(@as(?u5, 13), caps.get(0, 9).irq);
    try std.testing.expectEqual(@as(?u5, 12), caps.get(0, 8).irq);
    try std.testing.expectEqual(@as(?u5, 31), caps.get(1, 15).irq);
    try std.testing.expectEqual(@as(?u5, 21), caps.get(2, 14).irq);
    try std.testing.expectEqual(@as(?u5, 20), caps.get(2, 15).irq);
    try std.testing.expectEqual(@as(?u5, null), caps.get(2, 0).irq);
    try std.testing.expectEqual(@as(?u5, 24), caps.get(6, 6).irq);
}

test "analog enables and PSEL values follow the per-pad tables" {
    try std.testing.expect(caps.get(0, 9).analog);
    try std.testing.expect(caps.get(5, 13).analog);
    try std.testing.expect(!caps.get(1, 12).analog);
    try std.testing.expect(caps.get(1, 12).supportsFunction(4)); // TXD0_A
    try std.testing.expect(caps.get(1, 12).supportsFunction(25)); // LCD_DATA10_A
    try std.testing.expect(!caps.get(1, 12).supportsFunction(5));
    try std.testing.expect(!caps.get(0, 9).supportsFunction(3));
    const enables = caps.field.isel | caps.field.asel;
    try std.testing.expectEqual(enables, caps.get(0, 9).sanitize(enables));
    try std.testing.expectEqual(caps.field.isel, caps.get(1, 12).sanitize(enables));
    try std.testing.expectEqual(@as(u32, 0), caps.get(2, 0).sanitize(enables));
    // Undefined PSEL encodings and direction stay visible; do not invent a refusal.
    try std.testing.expectEqual(@as(u32, 0x1F01_0004), caps.get(0, 9).sanitize(0x1F01_0004));
}
