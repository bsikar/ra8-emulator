//! The data captured for each IT8951 display-area command.
const proto = @import("wire.zig");
pub const Event = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    waveform: u16,
};

pub const LogHook = struct {
    context: *anyopaque,
    refreshFn: *const fn (*anyopaque, Event) void,
};

pub fn notify(hook: ?LogHook, args: [5]u16, waveform: u16) void {
    const observer = hook orelse return;
    observer.refreshFn(observer.context, .{
        .x = args[proto.arg.display_x],
        .y = args[proto.arg.display_y],
        .width = args[proto.arg.display_width],
        .height = args[proto.arg.display_height],
        .waveform = waveform,
    });
}
