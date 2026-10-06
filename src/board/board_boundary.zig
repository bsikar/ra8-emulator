//! The board's boundary as the debugger's run passes it (RA8EMU-709).
//! Board.tick wants the guest events are pended on; under the debugger
//! that is CPU0's memory, the same guest a plain run ticks with. CPU1's
//! lines are re-pended by the boundary itself (events.rependOn).
const Board = @import("board.zig").Board;
const Guest = @import("../core/cpu/memory/guest.zig").Guest;
const Cpu = @import("../core/cpu/cpu.zig").Cpu;
const Reboot = @import("../core/reboot.zig").Reboot;
const systick_bank = @import("../core/systick_bank.zig");
const clocks = @import("../periph/clocks.zig");
const zig_boundary = @import("../debug/zig_boundary.zig");

pub const BoardBoundary = struct {
    board: *Board,
    core: Guest,
    cpu: ?*Cpu = null,
    reboot: ?*Reboot = null,
    timebase: clocks.Clocks = .{},
    ns_timebase: clocks.Clocks = .{ .words = systick_bank.non_secure_words },

    pub fn hook(self: *BoardBoundary) zig_boundary.Boundary {
        return .{ .context = self, .tickFn = tick };
    }

    fn tick(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *BoardBoundary = @ptrCast(@alignCast(context));
        try self.timebase.advance(self.core, instructions);
        try self.ns_timebase.advanceSysTick(self.core, instructions);
        try self.board.tick(self.core, instructions);
        const pending = self.reboot orelse return;
        if (!pending.requested) return;
        const cpu = self.cpu orelse return error.NoRebootCore;
        pending.requested = false;
        pending.performed +%= 1;
        const retired = cpu.retired;
        try cpu.reset(pending.vector_base);
        cpu.retired = retired;
    }
};
