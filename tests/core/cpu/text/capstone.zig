//! Checks one printer against Capstone over every 16-bit encoding its decode
//! group claims, at a fixed address.
const std = @import("std");
const ra8 = @import("ra8");
const decode = ra8.core.cpu.decode;
const Instr = ra8.core.cpu.instr.Instr;

pub const address: u32 = 0x0200_0100;
const shown_mismatches: usize = 8;

pub fn expectGroupMatches(group: []const u8) !void {
    var compared: usize = 0;
    var mismatched: usize = 0;
    var hw: u32 = 0;
    while (hw <= 0xFFFF) : (hw += 1) {
        const hw1: u16 = @intCast(hw);
        if (Instr.isWide(hw1)) continue;
        const instr: Instr = .{ .address = address, .hw1 = hw1, .size = 2 };
        const hit = decode.decode(instr) orelse continue;
        if (!std.mem.eql(u8, hit.group, group)) continue;
        compared += 1;
        if (try matches(instr)) continue;
        mismatched += 1;
    }
    try std.testing.expect(compared > 0);
    try std.testing.expectEqual(@as(usize, 0), mismatched);
}

/// The 32-bit form: every hw1 with `hw1 & mask == value`, each paired with
/// every hw2 in `samples`.
pub fn expectWideGroupMatches(group: []const u8, mask: u16, value: u16, samples: []const u16) !void {
    var compared: usize = 0;
    var mismatched: usize = 0;
    var hw: u32 = value;
    while (hw <= 0xFFFF) : (hw += 1) {
        const hw1: u16 = @intCast(hw);
        if (hw1 & mask != value) continue;
        for (samples) |hw2| {
            const instr: Instr = .{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 };
            const hit = decode.decode(instr) orelse continue;
            if (!std.mem.eql(u8, hit.group, group)) continue;
            compared += 1;
            if (try matches(instr)) continue;
            mismatched += 1;
        }
    }
    try std.testing.expect(compared > 0);
    try std.testing.expectEqual(@as(usize, 0), mismatched);
}

fn matches(instr: Instr) !bool {
    const all = [4]u8{ @truncate(instr.hw1), @truncate(instr.hw1 >> 8), @truncate(instr.hw2), @truncate(instr.hw2 >> 8) };
    const theirs = ra8.core.disasm.one(instr.address, all[0..instr.size]) catch return false;
    const ours = decode.text.disasm.one(instr) orelse return false;
    if (std.mem.eql(u8, ours.slice(), theirs.slice())) return true;
    std.debug.print("0x{x:0>4} {x:0>4}: ours \"{s}\", capstone \"{s}\"\n", .{ instr.hw1, instr.hw2, ours.slice(), theirs.slice() });
    return false;
}
