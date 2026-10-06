//! Answers session RPC requests against the core-addressed Session
//! (RA8EMU-735).
//!
//! Each route decodes one session_rpc message, makes the matching Session
//! call and encodes the reply. `run` and `step` reply once the run ends and
//! also queue a `stop` event, which `Host.poll` sends to a subscribed client
//! after any `uart` events the run produced (RA8EMU-758).
const std = @import("std");
const rpc = @import("ra8_rpc");
const proto = @import("session_rpc.zig");
const api = @import("../../debug/session_api.zig");
const handlers = @import("session_handlers.zig");
const uart_feed = @import("session_uart_feed.zig");
const lcd_feed = @import("session_lcd_feed.zig");
const parts = @import("session_parts.zig");
const session_advance = @import("session_advance.zig");
const session_files = @import("session_files.zig");

/// The framing library, for callers that only import the emulator.
pub const rpc_lib = rpc;

pub const Context = handlers.Context;
pub const app_codes = handlers.app_codes;

const M = proto.Method;
const routes = .{
    .{ @intFromEnum(M.load), handlers.load },
    .{ @intFromEnum(M.run), handlers.run },
    .{ @intFromEnum(M.pause), handlers.pause },
    .{ @intFromEnum(M.step), handlers.step },
    .{ @intFromEnum(M.set_speed), handlers.setSpeed },
    .{ @intFromEnum(M.read_register), handlers.readRegister },
    .{ @intFromEnum(M.write_register), handlers.writeRegister },
    .{ @intFromEnum(M.read_memory), handlers.readMemory },
    .{ @intFromEnum(M.write_memory), handlers.writeMemory },
    .{ @intFromEnum(M.set_breakpoint), handlers.setBreakpoint },
    .{ @intFromEnum(M.clear_breakpoint), handlers.clearBreakpoint },
    .{ @intFromEnum(M.set_watchpoint), handlers.setWatchpoint },
    .{ @intFromEnum(M.clear_watchpoint), handlers.clearWatchpoint },
    .{ @intFromEnum(M.subscribe), handlers.subscribe },
    .{ @intFromEnum(M.unsubscribe), handlers.unsubscribe },
    .{ @intFromEnum(M.now), handlers.now },
    .{ @intFromEnum(M.interrupt), handlers.interrupt },
    .{ @intFromEnum(M.set_run_budget), handlers.setRunBudget },
    .{ @intFromEnum(M.remove_point), handlers.removePoint },
    .{ @intFromEnum(M.plug), parts.plug },
    .{ @intFromEnum(M.unplug), parts.unplug },
    .{ @intFromEnum(M.set_fault), parts.setFault },
    .{ @intFromEnum(M.clear_fault), parts.clearFault },
    .{ @intFromEnum(M.list_parts), parts.listParts },
    .{ @intFromEnum(M.advance), session_advance.advance },
    .{ @intFromEnum(M.snapshot), session_files.snapshot },
    .{ @intFromEnum(M.restore), session_files.restore },
};

pub const Server = rpc.Server(Context, proto.max_payload, routes);

/// One served connection: the route table plus the events it owes.
pub const Host = struct {
    server: Server,

    /// `rx` buffers incoming frames and `context` must outlive the host.
    /// The connection starts with no subscriptions.
    pub fn init(wire: rpc.Transport, rx: []u8, context: *Context) Host {
        handlers.forget(context);
        return .{ .server = Server.init(wire, rx, context, proto.capabilities) };
    }

    /// Answer at most one frame, then send the UART bytes, the LCD dirty
    /// rectangles and the stop event it produced, in that order.
    pub fn poll(self: *Host, tx: []u8) rpc.Error!rpc.Step {
        const step = try self.server.poll(tx);
        const context = self.server.context;
        try uart_feed.pump(context, &self.server, tx);
        try lcd_feed.pump(context, &self.server, tx);
        if (context.pending) |stopped| {
            context.pending = null;
            if (context.wants(stopped.core, .stop)) {
                try self.server.emit(proto.Stopped, @intFromEnum(proto.Topic.stop), stopped, tx);
            }
        }
        return step;
    }
};
