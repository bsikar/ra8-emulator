//! Covers tools/example_budgets.zig: which budget each image runs at.
const std = @import("std");
const table = @import("example_table");

const budgets = table.budgets;

test "an image with no override keeps the caller's budget" {
    try std.testing.expectEqualStrings("5000000", budgets.pick("blink_hal.elf", "5000000").?);
    try std.testing.expectEqual(@as(?[]const u8, null), budgets.pick("blink_hal.elf", null));
}

test "a listed image gets its own budget at the default" {
    try std.testing.expectEqualStrings("20000000", budgets.pick("ra8_io_swap_demo.elf", null).?);
}

test "a listed image never runs at less than its own budget" {
    try std.testing.expectEqualStrings("20000000", budgets.pick("ra8_io_swap_demo.elf", "4000000").?);
}

test "a caller asking for more than the override wins" {
    try std.testing.expectEqualStrings("50000000", budgets.pick("ra8_io_swap_demo.elf", "50000000").?);
}

test "a caller budget that does not parse is passed through" {
    try std.testing.expectEqualStrings("lots", budgets.pick("ra8_io_swap_demo.elf", "lots").?);
}

test "every override parses and is named by its ELF" {
    for (budgets.overrides) |entry| {
        try std.testing.expect(std.mem.endsWith(u8, entry.image, ".elf"));
        _ = try std.fmt.parseInt(u64, entry.instructions, 10);
    }
}
