//! The chunk boundary, peripheral side: what the board does between two
//! stretches of execution.
//!
//! board.zig is the list of what the board is made of. This is the other
//! half: the order the blocks are stepped in, and where an event goes once
//! one of them has raised it. The two are separated because the order here
//! is load-bearing in a way the field list is not, the same reason the bus
//! order sits in wiring.zig rather than beside the blocks it attaches.
const engine = @import("../core/engine.zig");

const Board = @import("board.zig").Board;

/// The watchdog counts, a block with an event due raises it into the event
/// links, a reset the watchdog asked for is recorded as the boot cause, then
/// any line still latched re-pends. The controller picks straight
/// afterwards, so an interrupt raised here is entered in the same boundary
/// rather than a chunk later.
pub fn tick(self: *Board, core: engine.Engine) !void {
    self.watchdog.tick();
    self.heartbeat.tick();
    self.lowpower.tick();
    self.microphone.tick();
    self.clock.tick();
    self.interval.tick();
    self.pwm.tick();
    self.ptp.tick();
    self.trace.tick();
    self.rswitch.tick();
    try takeResetRequests(self, core);
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
    try drain(self, core, self.links.takeEvents());
    try self.events.repend(core);
}

/// Every event one block has due this boundary, offered one at a time.
fn drain(self: *Board, core: engine.Engine, events: anytype) !void {
    for (events.constSlice()) |event| try raise(self, core, event);
}

/// One event, offered to all three consumers of one. The links first, and
/// they see EVERY event, not just the four the ELC generates: an event fans
/// out to the ICU and the ELC at once, and a link conducts without consuming
/// it. Then the transfer controller, before the core: a DTCE slot belongs to
/// the DTC until its descriptor runs out.
pub fn raise(self: *Board, core: engine.Engine, event: u16) !void {
    _ = self.links.conduct(event);
    if (self.transfers.activate(core, &self.events, event)) |moved| {
        if (!moved.interrupt) return;
    }
    try self.events.raise(core, event);
}

/// Whoever asked for a reset this boundary hands the request to the reset
/// block, which latches the cause the firmware will read on the way back up.
/// A software request is then performed: the run has a reboot seam and the
/// firmware behind AIRCR is sitting in a wait loop expecting the part to go
/// away. A watchdog request still only latches, because the image that
/// tripped it has nothing waiting on the reboot.
///
/// The PPB windows are polled here too. They are RAM rather than bus blocks,
/// so nothing else would look at them: the cache geometry, and the MPU's
/// TYPE and CTRL.
pub fn takeResetRequests(self: *Board, core: anytype) !void {
    if (self.watchdog.reset_requested) {
        self.watchdog.reset_requested = false;
        self.causes.request(.watchdog);
    }
    if (self.heartbeat.reset_requested) {
        self.heartbeat.reset_requested = false;
        self.causes.request(.iwdt);
    }
    try self.caches.poll(core);
    try self.regions.poll(core);
    if (!try self.control.poll(core)) return;
    self.causes.request(.software);
    self.events.clearLatches();
    if (self.reboot) |pending| pending.requested = true;
}
