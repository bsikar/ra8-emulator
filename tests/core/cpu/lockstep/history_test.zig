//! Covers src/core/cpu/lockstep/history.zig.
const std = @import("std");
const ra8 = @import("ra8");
const history = ra8.core.cpu.lockstep.history;
const Instr = ra8.core.cpu.instr.Instr;

fn entry(address: u32) history.Entry {
    return .{ .address = address, .instr = .{ .address = address, .hw1 = 0xBF00, .hw2 = 0, .size = 2 } };
}

test "entries come back oldest first" {
    var recent: history.History = .{};
    recent.push(entry(0x10));
    recent.push(entry(0x12));
    recent.push(entry(0x14));
    try std.testing.expectEqual(@as(usize, 3), recent.len);
    try std.testing.expectEqual(@as(u32, 0x10), recent.at(0).address);
    try std.testing.expectEqual(@as(u32, 0x14), recent.at(2).address);
}

test "past its depth the ring keeps only the latest" {
    var recent: history.History = .{};
    var address: u32 = 0;
    while (address < history.depth + 3) : (address += 1) recent.push(entry(address));
    try std.testing.expectEqual(@as(usize, history.depth), recent.len);
    try std.testing.expectEqual(@as(u32, 3), recent.at(0).address);
    try std.testing.expectEqual(@as(u32, history.depth + 2), recent.at(history.depth - 1).address);
}
