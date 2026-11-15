//! Session RPC callback adapters for clocks, inspection, and host input.
const chip = @import("ra8_chip");
const harness = @import("ra8_session").harness;
const periph_list = @import("ra8_session").periph_list;
const region_map = @import("ra8_session").region.map;
const region_map_json = @import("ra8_session").region.map.json;
const region_map_text = @import("ra8_session").region.map.text;
const rtos_hook = @import("ra8_session").rtos.hook;
const rtos_names = @import("ra8_session").rtos.names;
const Served = @import("served_setup.zig").Served;
const session_api = @import("ra8_session").api;
const session_plug = @import("ra8_session").board.plug;
const stack_profile = @import("ra8_session").stack.profile;
const stack_samples = @import("ra8_session").stack.samples;
const std = @import("std");
const symbols = @import("ra8_session").symbols;

/// The host clock the lcd_dirty rate measures against (RA8EMU-822).
pub fn hostClock(context: *anyopaque) u64 {
    const self: *Served = @ptrCast(@alignCast(context));
    return @intCast(@max(0, std.Io.Timestamp.now(self.io, .awake).nanoseconds));
}

pub fn traceOn(context: *anyopaque) bool {
    const self: *Served = @ptrCast(@alignCast(context));
    const first = self.owner.traceIfRtos();
    const second = if (self.second) |cpu1| cpu1.traceIfRtos(&self.owner) else false;
    return first or second;
}

/// The name of the thread whose control block is at `thread` on `core`,
/// read from its TX_THREAD.
pub fn threadName(context: *anyopaque, core: usize, thread: u32, buffer: []u8) ?[]const u8 {
    if (thread == 0) return null;
    const self: *Served = @ptrCast(@alignCast(context));
    const memory = if (core == 0)
        rtos_hook.Memory{ .guest = self.owner.guest() }
    else
        rtos_hook.Memory{ .guest = (self.second orelse return null).guest() };
    return rtos_names.name(memory, thread, buffer[0..rtos_names.longest]);
}

pub fn closeC6(context: *anyopaque) void {
    const self: *Served = @ptrCast(@alignCast(context));
    self.owner.board().c6.wire.bridge.closeFlows();
}
pub fn feedConsoleDirect(context: *anyopaque, bytes: []const u8) anyerror!void {
    const self: *Served = @ptrCast(@alignCast(context));
    self.owner.board().serial.feed(chip.periph.sci.console_channel, bytes);
}
pub fn listParts(context: *anyopaque, out: []u8) anyerror![]const u8 {
    const plugs: *session_plug.Plugs = @ptrCast(@alignCast(context));
    return plugs.list(out);
}
/// The map of a core's last loaded image, as `--map` text or JSON.
pub fn mapImage(context: *anyopaque, core: usize, json: bool, out: []u8) anyerror![]const u8 {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    const which: session_api.Core = if (core == 0) .cpu0 else .cpu1;
    const image = owner.loadedImage(which) orelse return error.NoImage;
    var w: std.Io.Writer = .fixed(out);
    if (json) {
        try region_map_json.write(&w, image, &region_map.ek_ra8d2);
    } else {
        try region_map_text.render(&w, image, &region_map.ek_ra8d2);
    }
    return w.buffered();
}
/// The blocks on the board's bus, or one block's registers (RA8EMU-818).
/// Both cores share the one peripheral bus.
pub fn listPeriph(context: *anyopaque, core: usize, block: []const u8, json: bool, out: []u8) anyerror![]const u8 {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    return periph_list.list(&owner.board().bus, core, block, json, out);
}
/// A core's sampled stacks over [from_ns, to_ns), named by the image they
/// were walked with; a window, thread or core that took none is refused.
pub fn foldStacks(
    context: *anyopaque,
    core: usize,
    thread: ?u32,
    from_ns: u64,
    to_ns: u64,
    out: []u8,
) anyerror![]const u8 {
    const self: *Served = @ptrCast(@alignCast(context));
    const stacks = self.stacks orelse return error.NothingSampled;
    const image = if (core == 0) self.owner.image() else (self.second orelse return error.NothingSampled).image.?;
    var w: std.Io.Writer = .fixed(out);
    var scratch: [stack_samples.limits.samples]usize = undefined;
    const filter: stack_samples.Filter = .{
        .core = @intCast(core),
        .from_ns = from_ns,
        .to_ns = to_ns,
        .thread = thread,
    };
    try stack_samples.fold(&stacks.store, filter, stack_profile.names(&image), &w, &scratch);
    if (w.end == 0) return error.NothingSampled;
    return w.buffered();
}
/// The main stack reservation of a core's last loaded image, if it names one.
pub fn stackOf(context: *anyopaque, core: usize) ?region_map.Stack {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    const which: session_api.Core = if (core == 0) .cpu0 else .cpu1;
    const image = owner.loadedImage(which) orelse return null;
    return region_map.stackOf(image, &region_map.ek_ra8d2);
}
/// A core's last loaded image, for the backtrace's names and lines.
pub fn imageOf(context: *anyopaque, core: usize) ?symbols.Image {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    return owner.loadedImage(if (core == 0) .cpu0 else .cpu1);
}
