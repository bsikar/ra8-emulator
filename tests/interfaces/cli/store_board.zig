//! The board a `--cpu zig` run attaches, for tests that run CPU0 on its own
//! store: every block over the store, then CPU0's windows primed into it,
//! as zig_memory.Cpu0.attachStore does.
const ra8 = @import("ra8");

const wiring = ra8.board.wiring;
pub const Store = ra8.core.cpu.memory.store.Store;
pub const Guest = ra8.core.cpu.memory.guest.Guest;

pub fn attach(board: *ra8.board.Board, core: Guest) !void {
    try wiring.attachBlocks(board, core);
    try wiring.primeWindows(board, core, wiring.cpu0Windows(board));
}
