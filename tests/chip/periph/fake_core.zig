//! A core made of PPB words in a map and registers in an array: enough for
//! the fault raisers and the NVIC's exception entry, which only read and
//! write words and registers. Shared by the fault and DebugMonitor tests.
const std = @import("std");

pub const FakeCore = struct {
    pub const Name = enum { pc, sp, lr, r0, r1, r2, r3, r12, xpsr, primask, basepri, psp };

    words: std.AutoHashMap(u32, u32),
    registers: std.EnumArray(Name, u32) = std.EnumArray(Name, u32).initFill(0),

    pub fn init() FakeCore {
        return .{ .words = std.AutoHashMap(u32, u32).init(std.testing.allocator) };
    }

    pub fn deinit(self: *FakeCore) void {
        self.words.deinit();
    }

    /// Point vector n of the table at `table` to `handlers + 0x10 * n`.
    pub fn vectors(self: *FakeCore, table: u32, handlers: u32) !void {
        var number: u32 = 0;
        while (number < 16) : (number += 1) {
            try self.writeWord(table + 4 * number, handlers + 0x10 * number + 1);
        }
    }

    pub fn readWord(self: *FakeCore, address: u32) !u32 {
        return self.words.get(address) orelse 0;
    }

    pub fn writeWord(self: *FakeCore, address: u32, value: u32) !void {
        try self.words.put(address, value);
    }

    pub fn register(self: *FakeCore, which: Name) !u32 {
        return self.registers.get(which);
    }

    pub fn setRegister(self: *FakeCore, which: Name, value: u32) !void {
        self.registers.set(which, value);
    }
};
