//! The time bar's model side (RA8EMU-1086): fills the bar's plain view from
//! the status, the speed field and the clock readout, and turns a click into
//! a run or a pause of the shell's sliced run (src/interfaces/gui/shell/run.zig, RA8EMU-1118)
//! or a step on the session link. The bar itself (gui/ui/time_bar.zig) only
//! lays out, paints and hit-tests.
const proto = @import("ra8_rpc").session.rpc;
const bar = @import("../ui/time_bar.zig");
const status_bar = @import("../status/bar.zig");
const speed_field = @import("../speed_field.zig");
const time_readout = @import("readout.zig");
const session_link = @import("../session_link.zig");
const shell_run = @import("../shell/run.zig");

const Status = status_bar.Status;
const Link = session_link.Link;

comptime {
    if (bar.field_chars != speed_field.max_chars) @compileError("the time bar's field width must match speed_field.max_chars");
}

/// A step is one instruction; the session takes no budget for it.
pub const step_budget: u64 = 0;

/// The debugger step keys' keycodes (SDL: F-keys carry the scan-code mask).
pub const key_f10: u32 = 0x40000043;
pub const key_f11: u32 = 0x40000044;

/// F10 steps over, F11 steps into, shift+F11 steps out; null when not one.
pub fn keyControl(code: u32, shift: bool) ?bar.Control {
    return switch (code) {
        key_f10 => .over,
        key_f11 => if (shift) .out else .step,
        else => null,
    };
}

/// The buffers the view's field and clock text live in; they outlive the view.
pub const Texts = struct {
    field: [speed_field.max_chars + 4]u8 = undefined,
    date: [19]u8 = undefined,
    elapsed: [32]u8 = undefined,
    speed: [56]u8 = undefined,
};

/// The bar's view of `status`, `field` and `readout`, its text in `texts`.
pub fn view(texts: *Texts, status: *const Status, field: *const speed_field.Field, readout: *const time_readout.Readout, run: *const shell_run.Run, editing: bool, open: bool) bar.View {
    const p = readout.pieces(field.applied, &texts.date, &texts.elapsed, &texts.speed) catch time_readout.Readout.Pieces{};
    return .{
        .run_lit = run.lit,
        .run_enabled = enabled(.run, status, run),
        .pause_enabled = enabled(.pause, status, run),
        .step_enabled = enabled(.step, status, run),
        .over_enabled = enabled(.over, status, run),
        .out_enabled = enabled(.out, status, run),
        .note = if (status.refused == .run)
            "Run refused"
        else if (field.refused) |ref|
            ref.message()
        else if (status.load_id != null or status.pc_id != null)
            "Loading"
        else if (status.run == .unknown)
            "Load an image"
        else if (status.run_id != null or (!run.lit and run.slice_id != null))
            "Waiting for stop"
        else
            null,
        .command_refused = status.refused == .run or field.refused != null,
        .pause_lit = status.run == .halted,
        .field = field.shown(&texts.field) catch texts.field[0..0],
        .field_refused = field.refused != null,
        .editing = editing,
        .open = open,
        .applied = field.applied,
        .clock = p.elapsed,
        .clock_date = p.date,
        .clock_speed = p.speed,
    };
}

/// A click on `control`. Run lights `run` on a halted core, and the shell's
/// frames keep it going in slices from there; nothing is sent here, so the
/// window never waits on a run. Pause stops it between slices. Step runs
/// one instruction on a halted core. The field takes the keyboard in the
/// shell, so a click on it sends nothing.
pub fn press(control: bar.Control, status: *Status, run: *shell_run.Run, link: *Link) !void {
    if (!enabled(control, status, run)) return;
    if ((control == .run or control == .step) and link.state != .connected) return error.NotConnected;
    switch (control) {
        .run => {
            const at = switch (status.run) {
                .halted => |halt| halt.address,
                .unknown, .running => return,
            };
            run.start(at);
            status.running();
        },
        .step => {
            try status.go(link, proto.RunMode.step, step_budget);
            status.refused = null;
        },
        .over => {
            try status.go(link, proto.RunMode.next, step_budget);
            status.refused = null;
        },
        .out => {
            try status.go(link, proto.RunMode.finish, step_budget);
            status.refused = null;
        },
        .pause => run.pause(),
        .field, .drop => {},
    }
}

/// One policy for paint, mouse commands and menu/keyboard commands.
pub fn enabled(control: bar.Control, status: *const Status, run: *const shell_run.Run) bool {
    return switch (control) {
        .run, .step, .over, .out => status.run == .halted and !run.lit and run.slice_id == null and run.settled == null and status.load_id == null and status.pc_id == null and status.run_id == null,
        .pause => run.lit,
        .field, .drop => true,
    };
}
