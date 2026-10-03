//! Covers src/core/cpu/lockstep/run.zig.
const std = @import("std");
const ra8 = @import("ra8");
const run = ra8.core.cpu.lockstep.run;
const Pair = @import("pair.zig").Pair;

const nop_nop_udf = [_]u8{ 0x00, 0xBF, 0x00, 0xBF, 0x80, 0xBA };

test "a run counts what matched and ends where the Zig core stops" {
    const gpa = std.testing.allocator;
    var pair: Pair = undefined;
    try pair.open(&nop_nop_udf);
    defer pair.close();
    var lock: run.Run = .{};
    defer lock.deinit(gpa);
    const ended = try lock.go(gpa, &pair.cpu, pair.theirs, &pair.log, 10);
    try std.testing.expectEqual(@as(u16, 0xBA80), ended.stopped.unknown.hw1);
    try std.testing.expectEqual(@as(u64, 2), lock.counts.find("hint").?.matched);
    try std.testing.expectEqual(@as(usize, 2), lock.recent.len);
}

test "a run inside its budget ends on the budget" {
    const gpa = std.testing.allocator;
    var pair: Pair = undefined;
    try pair.open(&nop_nop_udf);
    defer pair.close();
    var lock: run.Run = .{};
    defer lock.deinit(gpa);
    try std.testing.expect((try lock.go(gpa, &pair.cpu, pair.theirs, &pair.log, 1)) == .budget);
}

test "a disagreement ends the run and is counted as diverged" {
    const gpa = std.testing.allocator;
    var pair: Pair = undefined;
    try pair.open(&nop_nop_udf);
    defer pair.close();
    try pair.theirs.setRegister(.r7, 7);
    var lock: run.Run = .{};
    defer lock.deinit(gpa);
    const ended = try lock.go(gpa, &pair.cpu, pair.theirs, &pair.log, 10);
    try std.testing.expectEqual(ra8.core.cpu.regs.Name.r7, ended.diverged.what.register.name);
    try std.testing.expectEqual(@as(u64, 1), lock.counts.find("hint").?.diverged);
}

const Rounds = struct {
    calls: u32 = 0,
    total: u32 = 0,

    fn hook(self: *Rounds) run.Between {
        return .{ .context = self, .roundFn = count };
    }

    fn count(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Rounds = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.total += instructions;
    }
};

test "a run hands a second core its turn after every full round" {
    const gpa = std.testing.allocator;
    var pair: Pair = undefined;
    // B . : runs as long as the budget lasts.
    try pair.open(&[_]u8{ 0xFE, 0xE7 });
    defer pair.close();
    var rounds: Rounds = .{};
    var lock: run.Run = .{ .between = rounds.hook(), .round = 10 };
    defer lock.deinit(gpa);
    try std.testing.expect((try lock.go(gpa, &pair.cpu, pair.theirs, &pair.log, 25)) == .budget);
    try std.testing.expectEqual(@as(u32, 2), rounds.calls);
    try std.testing.expectEqual(@as(u32, 20), rounds.total);
}
