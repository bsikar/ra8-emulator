//! The advance tests' shared rig (RA8EMU-654): the idler image served
//! the way `serve` serves one, the fake wall clock and the observed
//! guest state. Split out of the advance test file so the file stays
//! small; both advance test files import it.
const std = @import("std");
const ra8 = @import("ra8");
const idler = @import("../../cli/idler.zig");
const store_board = @import("../../cli/store_board.zig");

const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
const NvicSource = ra8.chip.core.cpu.exception.nvic_source.NvicSource;
const Machine = ra8.session.stop_machine.Machine;
const api = ra8.session.api;
const BoardBoundary = ra8.session.board.boundary.BoardBoundary;
const server = ra8.rpc.session.server;
const advance = ra8.rpc.session.advance;
const proto = ra8.rpc.session.rpc;

pub const hz: u64 = 25_000;
pub const period: u64 = 600 * hz;
pub const ns_per_s: u64 = std.time.ns_per_s;

/// The sleeper served as `serve` serves an image: a session on the Zig
/// core with the board's boundary, and the RPC context over it.
pub const Rig = struct {
    store: store_board.Store = undefined,
    guest: store_board.Guest = undefined,
    board: ra8.board.board.Board = undefined,
    memory: GuestBus = undefined,
    pending: NvicSource = .{},
    cpu: Cpu = undefined,
    machine: Machine = .{},
    edge: BoardBoundary = undefined,
    session: api.Session = undefined,
    scratch: [64]u8 = undefined,
    context: server.Context = undefined,
    pending1: NvicSource = .{},
    cpu1: Cpu = undefined,
    machine1: Machine = .{},

    pub fn open(self: *Rig) !void {
        self.store = try store_board.Store.init(null);
        errdefer self.store.deinit();
        self.guest = .{ .store = &self.store };
        try idler.load(self.guest);
        try self.guest.writeWord(memmap.syst.rvr, @intCast(period - 1));
        self.board = ra8.board.board.Board.init(std.testing.allocator);
        errdefer self.board.deinit();
        try store_board.attach(&self.board, self.guest);
        self.board.time.base.setRate(hz);
        self.memory = GuestBus.of(&self.guest, false);
        self.cpu = .{ .bus = self.memory.view(), .source = self.pending.source() };
        self.pending.banked = &self.cpu.banked;
        try self.cpu.reset(idler.base);
        self.edge = .{ .board = &self.board, .core = self.guest };
        self.session = .{ .live = .{ .core = .{ .cpu = &self.cpu }, .machine = &self.machine, .budget = 1000, .boundary = self.edge.hook() } };
        self.session.attachTimeBase(&self.board.time.base);
        self.context = .{ .session = &self.session, .scratch = &self.scratch };
    }

    pub fn close(self: *Rig) void {
        self.board.deinit();
        self.store.deinit();
    }

    pub fn advanceBy(self: *Rig, ns: u64) !proto.Advanced {
        return switch (advance.advance(&self.context, .{ .core = .cpu0, .ns = ns })) {
            .ok => |moved| moved,
            .err => error.Refused,
        };
    }

    pub fn advanceCore(self: *Rig, core: proto.Core, ns: u64) !proto.Advanced {
        return switch (advance.advance(&self.context, .{ .core = core, .ns = ns })) {
            .ok => |moved| moved,
            .err => error.Refused,
        };
    }

    pub fn wakes(self: *Rig) !u32 {
        return self.guest.readWord(idler.counter_at);
    }

    /// Park a second core on the same image, holding `budget`.
    pub fn park(self: *Rig, budget: u64) !void {
        self.cpu1 = .{ .bus = self.memory.view(), .source = self.pending1.source() };
        self.pending1.banked = &self.cpu1.banked;
        try self.cpu1.reset(idler.base);
        self.session.live.other = .{ .core = .{ .cpu = &self.cpu1 }, .machine = &self.machine1, .budget = budget };
    }

    pub fn seen(self: *Rig) !Seen {
        return .{
            .now_ns = try self.session.now(),
            .closed_ns = self.board.time.base.now(),
            .carry = self.edge.saved.stretch.carry,
            .full = self.edge.saved.stretch.full,
            .retired = self.cpu.retired,
            .pc = self.cpu.regs.pc,
            .wakes = try self.wakes(),
        };
    }
};

/// A host wall clock that moves one millisecond per read.
pub const FakeWall = struct {
    ns: u64 = 0,

    pub fn now(context: *anyopaque) u64 {
        const wall: *FakeWall = @ptrCast(@alignCast(context));
        wall.ns += 1_000_000;
        return wall.ns;
    }
};

/// Where the guest and the grid stand: what a split advance must leave
/// exactly as an unsplit one does.
pub const Seen = struct {
    now_ns: u64,
    /// The board's own clock, which moves only when a stretch closes.
    closed_ns: u64,
    carry: u32,
    full: u32,
    retired: u64,
    pc: u32,
    wakes: u32,
};

pub const cycle_ns: u64 = ns_per_s / hz;

pub fn failingTick(_: *anyopaque, _: u32) anyerror!void {
    return error.Injected;
}
