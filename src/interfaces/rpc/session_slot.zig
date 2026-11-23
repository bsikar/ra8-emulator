//! A stable service context owns zero or one heap-stable emulator session.
const std = @import("std");

const chip = @import("ra8_chip");
const connection = @import("session/connection.zig");
const handlers = @import("session/handlers.zig");
const lifecycle = @import("session/lifecycle.zig");
const proto = @import("session/rpc.zig");
const server = @import("session/server.zig");
const setup = @import("served_setup.zig");
const worker = @import("served_worker.zig");

pub const Options = struct {
    startup: setup.Startup = .{},
    history: ?setup.HistoryOpts = null,
    second: ?setup.SecondImage = null,
    context: ?*anyopaque = null,
    prepareFn: ?*const fn (?*anyopaque, *setup.Served) anyerror!void = null,
};

pub const Slot = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    context: handlers.Context,
    rx: []u8,
    tx: []u8,
    active: ?*setup.Served = null,
    pending: ?*setup.Served = null,
    options: Options,
    profile: ?[]u8 = null,
    active_profile: ?[]u8 = null,
    pending_profile: ?[]u8 = null,

    /// The slot stays at this address until deinit; contexts borrow its hooks.
    pub fn init(self: *Slot, gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
        const rx = try gpa.alloc(u8, 2 * server.Server.Env.max_frame);
        errdefer gpa.free(rx);
        const tx = try gpa.alloc(u8, server.Server.Env.max_frame);
        errdefer gpa.free(tx);
        const scratch = try gpa.alloc(u8, proto.max_payload);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .rx = rx,
            .tx = tx,
            .options = options,
            .context = .{ .scratch = scratch, .gpa = gpa, .transport_async = true },
        };
        self.options.startup.machine = options.startup.machine orelse &chip.core.machine.catalog.ra8d2;
        self.context.lifecycle = .{
            .context = self,
            .loadFn = load,
            .closeFn = close,
            .configureFn = configure,
            .machineFn = machine,
            .commitFn = commit,
            .discardFn = discard,
        };
    }

    pub fn deinit(self: *Slot) void {
        if (self.active) |source| worker.detach(source);
        connection.forget(&self.context);
        if (self.pending) |source| self.destroy(source);
        if (self.active) |source| self.destroy(source);
        if (self.profile) |bytes| self.gpa.free(bytes);
        if (self.active_profile) |bytes| self.gpa.free(bytes);
        if (self.pending_profile) |bytes| self.gpa.free(bytes);
        self.gpa.free(self.context.scratch);
        self.gpa.free(self.rx);
        self.gpa.free(self.tx);
    }

    fn destroy(self: *Slot, source: *setup.Served) void {
        source.deinit();
        self.gpa.destroy(source);
    }

    fn load(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *Slot = @ptrCast(@alignCast(ctx));
        if (self.pending != null or self.context.session_change_pending) return error.SessionBusy;
        const profile = if (self.profile) |p| try self.gpa.dupe(u8, p) else null;
        errdefer if (profile) |p| self.gpa.free(p);
        const candidate = try self.gpa.create(setup.Served);
        errdefer self.gpa.destroy(candidate);
        var startup = self.options.startup;
        startup.elf_bytes = bytes;
        try candidate.openInputs(self.gpa, self.io, "", profile, self.options.history, self.options.second, startup);
        errdefer candidate.deinit();
        if (self.options.prepareFn) |prepare| try prepare(self.options.context, candidate);
        if (self.active) |active| try active.flushHistory();
        self.pending = candidate;
        self.pending_profile = profile;
    }

    fn discard(ctx: *anyopaque) void {
        const self: *Slot = @ptrCast(@alignCast(ctx));
        if (self.pending) |source| self.destroy(source);
        self.pending = null;
        if (self.pending_profile) |bytes| self.gpa.free(bytes);
        self.pending_profile = null;
        self.context.session_change_pending = false;
    }

    fn close(ctx: *anyopaque) !void {
        const self: *Slot = @ptrCast(@alignCast(ctx));
        if (self.pending != null) return error.SessionBusy;
        if (self.active) |active| try active.flushHistory();
    }

    fn configure(ctx: *anyopaque, args: lifecycle.Configure) !void {
        const self: *Slot = @ptrCast(@alignCast(ctx));
        if (self.pending != null or self.context.chunks.buffer.len != 0) return error.SessionBusy;
        const chosen = chip.core.machine.catalog.find(args.machine) orelse return error.UnknownMachine;
        const profile = if (args.profile.len > 0) try self.gpa.dupe(u8, args.profile) else null;
        if (self.profile) |old| self.gpa.free(old);
        self.profile = profile;
        self.options.startup.machine = chosen;
    }

    fn machine(ctx: *anyopaque) []const u8 {
        const self: *Slot = @ptrCast(@alignCast(ctx));
        return (self.options.startup.machine orelse &chip.core.machine.catalog.ra8d2).name;
    }

    /// Runs after the response and after releasing the old worker's lock.
    fn commit(ctx: *anyopaque) void {
        const self: *Slot = @ptrCast(@alignCast(ctx));
        const topics = self.context.topics;
        const rates = self.context.lcd_rate;
        if (self.active) |source| worker.detach(source);
        connection.clearSession(&self.context);
        if (self.active) |old| self.destroy(old);
        if (self.active_profile) |old| self.gpa.free(old);
        self.active = self.pending;
        self.pending = null;
        self.active_profile = self.pending_profile;
        self.pending_profile = null;
        attachRuntime(&self.context, if (self.active) |source| &source.context else null);
        self.context.transport_async = true;
        self.context.topics = topics;
        self.context.lcd_rate = rates;
        if (self.active != null) restoreSubscriptions(&self.context, topics, rates);
    }
};

fn restoreSubscriptions(context: *handlers.Context, topics: [2]u8, rates: [2]u16) void {
    inline for (.{ proto.Core.cpu0, proto.Core.cpu1 }, 0..) |core, i| {
        inline for (@typeInfo(proto.Topic).@"enum".field_names, 0..) |name, bit| {
            if (topics[i] & (@as(u8, 1) << bit) != 0) {
                const request: proto.Subscription = .{
                    .core = core,
                    .topic = @field(proto.Topic, name),
                    .rate = rates[i],
                };
                _ = handlers.subscribe(context, request);
            }
        }
    }
}

fn attachRuntime(context: *handlers.Context, source: ?*handlers.Context) void {
    const empty: handlers.Context = .{ .scratch = context.scratch };
    const runtime = source orelse &empty;
    inline for (.{
        "session", "pending",         "state",   "listing",  "board_profile", "camera",     "mapping",   "peripherals",
        "folding", "clock",           "modules", "trace_on", "thread_names",  "host_clock", "transport", "wall",
        "worker",  "transport_async", "nav",
    }) |field| {
        @field(context, field) = @field(runtime, field);
    }
}
