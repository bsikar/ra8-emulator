const std = @import("std");
const pads = @import("ra8").chip.periph.pfs.capabilities.pads;

test "canonical pad records preserve port order and hardware exceptions" {
    try std.testing.expectEqual(@as(usize, 208), pads.records.len);
    try std.testing.expectEqual(@as(?u5, 6), pads.records[0].irq); // P000
    try std.testing.expectEqual(@as(u32, 1), pads.records[0].functions);
    try std.testing.expect(!pads.records[32].output); // P200
    try std.testing.expectEqual(@as(?u5, 10), pads.records[176].irq); // PB00
    try std.testing.expectEqual(@as(?u5, 28), pads.records[184].irq); // PC00
    try std.testing.expectEqual(@as(?u5, 23), pads.records[200].irq); // PD00
    try std.testing.expectEqual(@as(?u5, 17), pads.records[207].irq); // PD07
    for (pads.records) |pad| {
        try std.testing.expect(pad.functions & 1 != 0);
        try std.testing.expect(pad.functions & 0x8000_0000 == 0);
    }
}
