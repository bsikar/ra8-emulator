//! Reverse execution and clean-image restart for DAP sessions with history.
const std = @import("std");

const inspection = @import("inspection.zig");
const p = @import("protocol.zig");
const Points = @import("points.zig").Points;
const session = @import("ra8_session");

pub const Stop = struct {
    core: session.api.Core,
    reason: []const u8,
};

pub fn supported(target: ?inspection.Target) bool {
    const t = target orelse return false;
    const h = t.session.history orelse return false;
    return t.session.window_driver == null and h.capacity > 0;
}

pub fn handles(command: []const u8) bool {
    return std.mem.eql(u8, command, "stepBack") or
        std.mem.eql(u8, command, "reverseContinue") or
        std.mem.eql(u8, command, "restart");
}

pub fn run(
    target: inspection.Target,
    inspect: *inspection.Inspection,
    points: *const Points,
    configured: bool,
    command: []const u8,
    args: p.Value,
) !Stop {
    if (!supported(target)) return error.UnsupportedRequest;
    if (!configured) return error.NotConfigured;
    if (std.mem.eql(u8, command, "restart")) {
        try target.session.resetImage();
        try inspect.invalidate();
        return .{ .core = target.session.currentCore(), .reason = "entry" };
    }
    const core = try inspection.Inspection.thread(target, args);
    if (std.mem.eql(u8, command, "stepBack")) {
        const granularity = p.get(args, "granularity");
        if (granularity == .null or !std.mem.eql(u8, try p.text(granularity), "instruction")) {
            return error.UnsupportedGranularity;
        }
        try target.session.stepBack(core);
        try inspect.invalidate();
        return .{ .core = core, .reason = "step" };
    }
    try target.session.reverseContinue(core);
    try inspect.invalidate();
    const machine = try target.session.machine(core);
    const pc = try target.session.register(core, .pc);
    const reason: []const u8 = if (machine.breaks.hit(pc)) |id|
        (if (points.isInstruction(core, id)) "instruction breakpoint" else "breakpoint")
    else
        "step";
    return .{ .core = core, .reason = reason };
}
