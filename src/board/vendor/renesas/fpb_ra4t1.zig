//! FPB-RA4T1 (`RTK7FPA4T1S00001BE` / `R7FA4T1BB3CFM`) board wiring and
//! boundary tick helpers (`RA8EMU-A-71`).
const board_root = @import("../../root.zig");
const chip = @import("ra8_chip");

const boundary = board_root.boundary;
const Guest = chip.core.cpu.memory.guest.Guest;
const ra4t1 = chip.vendor.renesas.ra4t1;
const registry = chip.periph.registry;
const Board = board_root.board.Board;

/// Seed erased flash/ROM regions, attach RA4T1 MMIO blocks, and bind internal callbacks.
pub fn attachBlocks(self: *Board, memory: Guest) !void {
    try ra4t1.seedRom(memory);
    try self.ra4t1.attachToBus(&self.bus);
    bind(self);
}

/// Bind RA4T1 internal guard pointers (`PRCR.PRC4`), classic `SCI9` serial forwarding,
/// and live `PSCU` IDAU callbacks onto `self`.
pub fn bind(self: *Board) void {
    self.ra4t1.bindSelf();
    self.ra4t1.bindIrq();
    self.ra4t1.sci.tx_sink = .{ .context = self, .onByteFn = forwardSciTx };
    self.idau.custom = self.ra4t1.pscu.callback();
}

/// Advance the RA4T1 clock timebase, timers, reset requests, and ICU interrupt delivery.
pub fn tick(self: *Board, core: Guest, instructions: u32, issuer: registry.Issuer) !void {
    if (self.event_sink) |sink| sink.observeFn(sink.context, issuer, self.time.base.now(), boundary.observation(self));
    const before_ns = self.time.base.now();
    self.time.base.setRate(self.ra4t1.sysc.iclkHz());
    self.time.base.advance(instructions);
    const elapsed_ns = self.time.base.now() - before_ns;
    self.ra4t1.timers.tick(elapsed_ns, self.ra4t1.sysc.pclkdHz(), self.ra4t1.sysc.pclkbHz());
    boundary.notifyFrameTaps(self);
    try boundary.takeResetRequestsFrom(self, core, issuer);
    try drainEvents(self, core);
    try boundary.irqSource(self, .cpu0).repend(&core, self.desc().primary().scs.irq_lines);
    if (self.reboot) |pending| if (pending.requested) boundary.clearIrqLatches(self);
    if (self.run_hook) |hook| hook.boundaryFn(hook.context, self.time.base.now());
}

fn drainEvents(self: *Board, core: Guest) !void {
    const due = self.ra4t1.timers.takeEvents();
    const lines = self.desc().primary().scs.irq_lines;
    for (due.slice()) |event| {
        try boundary.irqSource(self, .cpu0).raise(&core, lines, event);
    }
}

fn forwardSciTx(context: *anyopaque, sci_index: u4, byte: u8) void {
    const self: *Board = @ptrCast(@alignCast(context));
    if (sci_index < self.serial.channels.len) {
        self.serial.channels[sci_index].transmitted +%= 1;
    }
    if (sci_index == 9) self.serial.line.feed(byte);
    if (self.serial.tap) |hook| hook.sent(hook.ctx, sci_index, byte);
}
