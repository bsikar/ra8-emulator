const std = @import("std");
const ra8 = @import("ra8");
const pend_break = ra8.core.pend_break;
const pend_resume = ra8.core.pend_resume;

/// A core with a program counter and one word of code at 0x1000.
const Core = struct {
    pc: u32,
    code: u32,

    pub fn register(self: *Core, which: anytype) !u32 {
        _ = which;
        return self.pc;
    }

    pub fn setRegister(self: *Core, which: anytype, value: u32) !void {
        _ = which;
        self.pc = value;
    }

    pub fn readWord(self: *Core, address: u32) !u32 {
        if (address != 0x1000) return error.Unmapped;
        return self.code;
    }
};

test "a narrow store is stepped past by two bytes" {
    var core = Core{ .pc = 0x1000, .code = 0xF3EF_601A };
    var pending = pend_break.Pend{ .ended_at = 0x1000 };
    try pend_resume.pastStore(&core, &pending);
    try std.testing.expectEqual(@as(u32, 0x1002), core.pc);
    try std.testing.expectEqual(@as(?u32, 0x1002), pending.resume_at);
}

test "a wide store is stepped past by four bytes" {
    var core = Core{ .pc = 0x1000, .code = 0x2000_F8C8 };
    var pending = pend_break.Pend{ .ended_at = 0x1000 };
    try pend_resume.pastStore(&core, &pending);
    try std.testing.expectEqual(@as(u32, 0x1004), core.pc);
}

test "the upper halfword is read for a store at a halfword offset" {
    var core = Core{ .pc = 0x1002, .code = 0x601A_F8C8 };
    var pending = pend_break.Pend{ .ended_at = 0x1002 };
    try pend_resume.pastStore(&core, &pending);
    try std.testing.expectEqual(@as(u32, 0x1004), core.pc);
}

test "a core that already left the store is not moved" {
    var core = Core{ .pc = 0x2000, .code = 0 };
    var pending = pend_break.Pend{ .ended_at = 0x1000 };
    try pend_resume.pastStore(&core, &pending);
    try std.testing.expectEqual(@as(u32, 0x2000), core.pc);
    try std.testing.expectEqual(@as(?u32, null), pending.resume_at);
}

test "a stretch opening past the store counts as a re-entry" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x1000);
    pending.steppedPast(0x1002);
    pending.boundary(0x1002);
    try std.testing.expectEqual(@as(usize, 1), pending.reentered);
    try std.testing.expectEqual(@as(usize, 0), pending.reopened);
    try std.testing.expectEqual(@as(?u32, null), pending.resume_at);
}
