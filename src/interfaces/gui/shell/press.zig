//! The shell loop's press routing (RA8EMU-1187): the handlers behind the
//! loop's button, pointer and key events, split out of shell/loop.zig so it
//! keeps to the frame itself. Each takes the shell the event hit.
const platform = @import("../platform.zig");
const pane_layout = @import("../ui/pane_layout.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const shell_loop = @import("loop.zig");
const map_pane = @import("../ui/map_pane.zig");
const session_link = @import("../session_link.zig");

const Shell = shell_loop.Shell;

/// A debugger step key over a source or disassembly pane (RA8EMU-1188).
pub fn stepKeys(shell: *Shell, event: platform.Event, solved: *const pane_layout.Solved) bool {
    const key = if (event == .key) event.key else return false;
    if (!key.down or key.primary) return false;
    var in_pane = false;
    for (solved.panes.items) |placed| {
        const pane = shell.layout.pane(placed.index) orelse continue;
        if (pane.kind != .source and pane.kind != .disasm) continue;
        if (shell_frame.bodyOf(placed.area).contains(shell.pointer_at.x, shell.pointer_at.y)) in_pane = true;
    }
    if (!in_pane) return false;
    const time = shell.time orelse return false;
    const link = shell.link orelse return false;
    return time.stepKey(key.code, key.shift, &shell.status, link);
}
/// Page Up or Page Down over a console leaf (RA8EMU-1122).
pub fn pageConsole(shell: *Shell, event: platform.Event, solved: *const pane_layout.Solved) bool {
    const key = if (event == .key) event.key else return false;
    const console = shell.console orelse return false;
    if (!key.down) return false;
    return console.pageIn(&shell.layout, solved, shell.pointer_at.x, shell.pointer_at.y, key.code);
}
/// Offer a press to the register editor over a value cell.
pub fn pressValue(shell: *Shell, x: i32, y: i32, solved: *const pane_layout.Solved) bool {
    const edit = shell.edit orelse return false;
    const registers = shell.registers orelse return false;
    return edit.press(registers, &shell.layout, solved, x, y);
}
/// A click on a map block pins the memory leaf to the block's start.
pub fn pressMap(shell: *Shell, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
    const map = shell.map orelse return false;
    const model = &(map.layout orelse return false);
    for (solved.panes.items) |placed| {
        const pane = shell.layout.pane(placed.index) orelse continue;
        if (pane.kind != .map) continue;
        const address = map_pane.click(model, shell_frame.bodyOf(placed.area), x, y) orelse continue;
        if (shell.memory) |memory| memory.pinTo(address);
        return true;
    }
    return false;
}
/// Offer a press to the text fields and the time bar.
pub fn pressFields(shell: *Shell, x: i32, y: i32) bool {
    const in_plug = if (shell.plug) |plug| plug.press(x, y) else false;
    const in_file = if (shell.camera_file) |file| file.press(x, y) else false;
    const in_memory = if (shell.memory_field) |field| field.press(x, y) else false;
    return pressBar(shell, x, y) or in_plug or in_file or in_memory;
}
/// Offer a press to the time bar: the timeline cursor's home.
pub fn pressBar(shell: *Shell, x: i32, y: i32) bool {
    const time = shell.time orelse return false;
    const link = shell.link orelse return false;
    return time.press(shell.bar, x, y, &shell.status, link);
}
/// Offer a press to the open speed dropdown popover.
pub fn pressDropdown(shell: *Shell, x: i32, y: i32) bool {
    const time = shell.time orelse return false;
    const link = shell.link orelse return false;
    return time.pressDropdown(shell.bar, x, y, link);
}
/// Board time for an input: what the time bar last knew, or zero.
pub fn boardNow(shell: *const Shell) u64 {
    const time = shell.time orelse return 0;
    return time.boardNow();
}
/// Offer a press to the session-backed panes: faults, devices, run-to points.
pub fn pressLink(shell: *Shell, link: *session_link.Link, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
    const devices = shell.devices orelse return false;
    if (shell.faults) |faults| if (faults.clickIn(link, devices, &shell.layout, solved, x, y)) return true;
    if (devices.clickIn(link, &shell.layout, solved, x, y)) return true;
    if (shell.breaks) |breaks| if (shell.code) |code| if (breaks.clickIn(link, code, &shell.layout, solved, x, y)) return true;
    if (shell.locals) |locals| if (shell.stack) |stack| if (locals.clickIn(stack, &shell.layout, solved, x, y)) return true;
    return false;
}
/// Offer a left press to the board leaf: a switch, or the panel.
pub fn pressBoard(shell: *Shell, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
    const pointer = shell.board_input orelse return false;
    const board = shell.board orelse return false;
    return pointer.down(board, &shell.layout, solved, x, y, boardNow(shell));
}
pub fn moveBoard(shell: *Shell, x: i32, y: i32) void {
    const pointer = shell.board_input orelse return;
    const board = shell.board orelse return;
    pointer.move(board, x, y);
}
/// The left button came up: the board leaf sends the click or touch under way.
pub fn releaseBoard(shell: *Shell, solved: *const pane_layout.Solved, x: i32, y: i32) void {
    if (shell.titles.release(&shell.layout, solved, x, y)) return;
    const pointer = shell.board_input orelse return;
    const board = shell.board orelse return;
    const link = shell.link orelse return;
    pointer.up(board, link, x, y, boardNow(shell));
}
