//! The chunk boundary, peripheral side: what the board does between two
//! stretches of execution.
//!
//! board.zig is the list of what the board is made of. This is the other
//! half: the order the blocks are stepped in, and where an event goes once
//! one of them has raised it. The two are separated because the order here
//! is load-bearing in a way the field list is not, the same reason the bus
//! order sits in wiring.zig rather than beside the blocks it attaches.
const Guest = @import("../core/cpu/memory/guest.zig").Guest;

const Board = @import("board.zig").Board;
const reset = @import("../periph/reset.zig");
const pin_irq = @import("../periph/icu/icu_pin_irq.zig");
const agt_sched = @import("../periph/agt/agt_sched.zig");
const gpt_sched = @import("../periph/gpt/gpt_sched.zig");

/// Cycles at the time base's rate until the next event on the board's
/// queue, zero when nothing is queued or it is already due. The pace reads
/// this to close a boundary on it (src/core/queue_pace.zig).
pub fn cyclesToDue(context: *anyopaque) u64 {
    const board: *const Board = @ptrCast(@alignCast(context));
    const at = board.time.queue.next() orelse return 0;
    return board.time.base.cyclesUntil(at);
}

/// The watchdog counts, a block with an event due raises it into the event
/// links, a reset the watchdog asked for is recorded as the boot cause, then
/// any line still latched re-pends. The controller picks straight
/// afterwards, so an interrupt raised here is entered in the same boundary
/// rather than a chunk later.
pub fn tick(self: *Board, core: Guest, instructions: u32) !void {
    const before_ns = self.time.base.now();
    self.time.base.advance(instructions);
    const elapsed_ns = self.time.base.now() - before_ns;
    self.watchdog.tickFor(elapsed_ns);
    self.heartbeat.tickFor(elapsed_ns);
    self.lowpower.tick();
    self.microphone.tick();
    self.clock.tick();
    agt_sched.tickFor(&self.interval, before_ns, self.time.base.now());
    try agt_sched.arm(&self.interval, &self.time.queue, self.time.base.now());
    gpt_sched.tickFor(&self.pwm, before_ns, self.time.base.now());
    self.ptp.tick(instructions);
    self.trace.tick();
    self.rswitch.tick();
    self.usb.tick();
    if (self.display.output.vsync) |*frame| frame.tick(self.time.base.now());
    try takeResetRequests(self, core);
    self.c6.tick(&self.pins);
    self.console_input.poll(&self.serial);
    self.touch_input.poll(&self.wire.panel, &self.pins);
    try raisePinEdges(self, core);
    try drain(self, core, self.serial.dueEvents());
    try drain(self, core, self.lowpower.dueEvents());
    try drain(self, core, self.mailbox.dueEvents());
    try drain(self, core, self.can.dueEvents());
    try drain(self, core, self.npu.dueEvents());
    try drain(self, core, self.clock.dueEvents());
    try drain(self, core, self.interval.dueEvents());
    try drain(self, core, self.pwm.dueEvents());
    try drain(self, core, self.adc.dueEvents());
    try drain(self, core, self.dma.dueEvents());
    try drain(self, core, self.usb.dueEvents());
    try drain(self, core, self.links.takeEvents());
    try self.events.repend(core);
    if (self.cpu1) |second| try self.events.rependOn(.cpu1, second);
}

/// Host switch edges reach the event path only through a pin whose PFS ISEL
/// is set, and only in the sense its IRQCR picked (RA8EMU-375).
fn raisePinEdges(self: *Board, core: Guest) !void {
    for (self.touch_input.edges.take()) |edge| {
        if (pin_irq.fires(&self.pinfunc, &self.events.pins, edge)) try raise(self, core, pin_irq.eventOf(edge));
    }
}

/// Every event one block has due this boundary, offered one at a time.
fn drain(self: *Board, core: Guest, events: anytype) !void {
    for (events.constSlice()) |event| try raise(self, core, event);
}

/// One event, offered to all three consumers of one. The links first, and
/// they see EVERY event, not just the four the ELC generates: an event fans
/// out to the ICU and the ELC at once, and a link conducts without consuming
/// it. Then the transfer controller, before the core: a DTCE slot belongs to
/// the DTC until its descriptor runs out.
pub fn raise(self: *Board, core: Guest, event: u16) !void {
    _ = self.links.conduct(event);
    // INTSELR hands the event to CPU1's ICU. With no CPU1 attached it stays
    // CPU0's, which keeps a single-core run what it was.
    if (self.events.select.coreFor(event) == .cpu1) {
        if (self.cpu1) |second| {
            if (self.transfers1.activate(second, &self.events, event)) |moved| {
                if (!moved.interrupt) return;
            }
            return self.events.raiseOn(.cpu1, second, event);
        }
    }
    if (self.transfers.activate(core, &self.events, event)) |moved| {
        if (!moved.interrupt) return;
    }
    try self.events.raise(core, event);
}

/// Whoever asked for a reset this boundary hands the request to the reset
/// block, which latches the cause the firmware will read on the way back up,
/// and then the reset is performed through the run's reboot seam. That holds
/// for all three sources: the firmware behind AIRCR sits in a wait loop
/// expecting the part to go away, and an image that let a watchdog underflow
/// is either waiting on that reboot to read WDTRF or IWDTRF back
/// (wdt_reset_recovery_demo's second boot is its pass banner) or would have
/// been reset on silicon anyway, so carrying on past it reports a run the
/// bench never sees.
///
/// The PPB windows are polled here too. They are RAM rather than bus blocks,
/// so nothing else would look at them: the cache geometry, and the MPU's
/// TYPE and CTRL.
pub fn takeResetRequests(self: *Board, core: anytype) !void {
    if (self.watchdog.reset_requested) {
        self.watchdog.reset_requested = false;
        resetFor(self, .watchdog);
    }
    if (self.heartbeat.reset_requested) {
        self.heartbeat.reset_requested = false;
        resetFor(self, .iwdt);
    }
    try self.clears.apply(core);
    try self.caches.poll(core);
    try self.regions.poll(core);
    if (try self.control.poll(core)) resetFor(self, .software);
}

/// Latch one cause and ask for the reboot. The interrupt latches go down on
/// the way past: a line still pending would be entered before the firmware
/// coming back up has put its vector table back.
pub fn resetFor(self: *Board, source: reset.Source) void {
    self.causes.request(source);
    self.events.clearLatches();
    self.second_core.reset();
    if (self.reboot) |pending| pending.requested = true;
}
