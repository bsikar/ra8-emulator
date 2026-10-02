//! Debugger commands on the Zig core, answered in the Unicorn session's
//! words (RA8EMU-114). src/debug/session.zig carries a command out on the
//! Unicorn engine; this carries the same commands out on a ZigSession, and
//! prints through session_report and session_view, so one script gives one
//! transcript on either CPU. Core switching is not here yet.
const std = @import("std");
const break_table = @import("break_table.zig");
const commands = @import("commands.zig");
const elf = @import("../core/elf.zig");
const session = @import("session.zig");
const session_place = @import("session_place.zig");
const session_report = @import("session_report.zig");
const session_view = @import("session_view.zig");
const watch_table = @import("watch_table.zig");
const zig_session = @import("zig_session.zig");

pub const Error = error{Unsupported};

const Temporary = std.BoundedArray(break_table.Id, break_table.limits.capacity);

pub const ZigScript = struct {
    session: zig_session.ZigSession,
    image: ?elf.Image = null,
    temporary: Temporary = .{},

    /// Carry out one command. A command that fails prints why and the
    /// script carries on, as on Unicorn.
    pub fn apply(self: *ZigScript, command: commands.Command, out: anytype) !session.Outcome {
        if (command == .quit) {
            try self.session.machine.itm.flush(out, true);
            return .quit;
        }
        self.dispatch(command, out) catch |err| {
            try out.print("error: {s}\n", .{@errorName(err)});
        };
        return .more;
    }

    fn dispatch(self: *ZigScript, command: commands.Command, out: anytype) !void {
        const view = self.session.view();
        switch (command) {
            .brk => |at| try self.setBreak(at, false, out),
            .tbreak => |at| try self.setBreak(at, true, out),
            .delete => |id| try self.deleteBreak(id, out),
            .run => try self.go(.run, out),
            .cont => try self.go(.cont, out),
            .step => try self.go(.step, out),
            .next => try self.go(.next, out),
            .finish => try self.go(.finish, out),
            .registers => try session_view.registers(out, view),
            .examine => |want| try session_view.words(out, view, try self.resolve(want.place), want.words),
            .print => |text| try session_view.word(out, view, text, try self.resolve(text)),
            .backtrace => try session_report.backtrace(view, self.image, out),
            .watch => |want| try self.setWatch(want, out),
            else => return Error.Unsupported,
        }
    }

    fn resolve(self: *const ZigScript, text: []const u8) !u32 {
        return session_place.resolve(self.session.view(), self.image, text);
    }

    fn setBreak(self: *ZigScript, at: commands.At, temporary: bool, out: anytype) !void {
        const address = try self.resolve(at.place) & ~@as(u32, 1);
        const id = try self.session.machine.addBreak(.{ .address = address, .arrival = at.arrival });
        if (temporary) try self.temporary.append(id);
        try out.print("{s} {d} at ", .{ if (temporary) "Temporary breakpoint" else "Breakpoint", id });
        try session_report.where(self.image, address, out);
        if (at.arrival > 1) try out.print(", arrival {d}", .{at.arrival});
        try out.print("\n", .{});
    }

    /// As session.zig's setWatch. It stops only when the session has a
    /// listening bus (ZigSession.watch).
    fn setWatch(self: *ZigScript, want: commands.Watch, out: anytype) !void {
        const address = try self.resolve(want.place);
        const span = try watch_table.Watch.span(address, session.limits.watch_bytes, want.kind);
        const id = try self.session.machine.addWatch(span);
        try out.print("Watchpoint {d} ({s}) at 0x{X:0>8}\n", .{ id, @tagName(want.kind), address });
    }

    fn deleteBreak(self: *ZigScript, id: break_table.Id, out: anytype) !void {
        const machine = self.session.machine;
        machine.breaks.remove(id) catch |err| {
            machine.watches.remove(id) catch return err;
            return out.print("Deleted watchpoint {d}\n", .{id});
        };
        self.forget(id);
        try out.print("Deleted breakpoint {d}\n", .{id});
    }

    fn forget(self: *ZigScript, id: break_table.Id) void {
        const index = std.mem.indexOfScalar(break_table.Id, self.temporary.constSlice(), id) orelse return;
        _ = self.temporary.swapRemove(index);
    }

    /// Run under `command` and say how it ended, in session.zig's words.
    fn go(self: *ZigScript, command: zig_session.Command, out: anytype) !void {
        const ended = try self.session.go(command);
        const view = self.session.view();
        const pc = try view.register(.pc);
        try self.session.machine.itm.flush(out, false);
        const stop = switch (ended) {
            .stop => |why| why,
            .count => {
                try out.print("Budget of {d} instructions spent at ", .{self.session.budget});
                try session_report.where(self.image, pc, out);
                return out.print("\n", .{});
            },
            .core => |why| {
                try out.print("Fault: {s} at ", .{@tagName(why)});
                try session_report.where(self.image, pc, out);
                return out.print("\n", .{});
            },
        };
        const temporary = stop == .breakpoint and std.mem.indexOfScalar(break_table.Id, self.temporary.constSlice(), stop.breakpoint) != null;
        if (temporary) {
            try self.session.machine.breaks.remove(stop.breakpoint);
            self.forget(stop.breakpoint);
        }
        try session_report.prefix(out, stop, temporary);
        try session_report.line(view, self.image, pc, out);
    }
};
