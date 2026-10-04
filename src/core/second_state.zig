//! CPU1's run state, apart from whatever runs its instructions (RA8EMU-589).
//! Unicorn's `Second` embeds one beside its engine; a Zig CPU1 on its own
//! store (RA8EMU-588) carries one with no engine at all. Everything here
//! reads and writes CPU1's memory only through a memory.Guest.
const engine = @import("engine.zig");
const memmap = @import("memmap.zig");
const nvic = @import("../periph/nvic.zig");
const clocks = @import("../periph/clocks.zig");
const second_wait = @import("second_wait.zig");
const rate = @import("core_rate.zig");
const Board = @import("../board/board.zig").Board;
const Guest = @import("cpu/memory/guest.zig").Guest;

pub const State = struct {
    /// Where CPU1 stopped at the end of its last turn.
    pc: u32 = 0,
    /// Instructions CPU1 has run so far.
    ran: usize = 0,
    /// Turns CPU1 has been given, including ones it spent parked.
    turns: usize = 0,
    /// Set once CPU1 stops on a fault; it stays halted from then on.
    fault: ?engine.Fault = null,
    /// CPU1's own NVIC, vectored from its own table.
    interrupts: nvic.Nvic = .{},
    /// CPU1's Secure SysTick, which also keeps its DWT_CYCCNT.
    timebase: clocks.Clocks = .{},
    /// CPU1 parked in WFE, and what woke it.
    wait: second_wait.Wait = .{},
    /// The board, for a system reset that holds CPU1 until CPU0 releases it.
    board: ?*Board = null,
    resets_seen: u32 = 0,
    held: bool = false,
    restarts: u32 = 0,
    /// Set when CPU1 leaves reset and its registers still need the reset
    /// vector; whoever runs CPU1's instructions clears it.
    unvectored: bool = false,
    vector_base: u32 = 0,
    /// Bytes of CPU1's image loaded at open.
    written: u32 = 0,
    /// SCKDIVCR2, which sizes CPU1's turns against CPU0's.
    dividers: ?*const u16 = null,

    /// CPU1's turn, in instructions, for one CPU0 round of `round`.
    pub fn turn(self: *const State, round: u32) u32 {
        const word = if (self.dividers) |at| at.* else 0;
        return rate.turn(round, word);
    }

    /// Whether CPU1 sits in reset after a system reset. Once CPU0 releases
    /// it, its VTOR is primed through `memory` and it is marked unvectored.
    pub fn heldInReset(self: *State, memory: Guest) bool {
        const board = self.board orelse return self.held;
        const pending = board.reboot orelse return self.held;
        if (pending.performed != self.resets_seen) {
            self.resets_seen = pending.performed;
            self.held = true;
        }
        if (self.held and board.second_core.running()) self.leaveReset(memory, board.second_core.initvtor);
        return self.held;
    }

    fn leaveReset(self: *State, memory: Guest, initvtor: u32) void {
        const base = if (initvtor != 0) initvtor else self.vector_base;
        self.held = false;
        self.restarts +%= 1;
        self.unvectored = true;
        self.vector_base = base;
        self.interrupts = .{ .vector_base = base };
        self.wait = .{};
        memory.writeWord(memmap.scb.vtor, base) catch {};
    }
};
