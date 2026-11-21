//! The chunk boundary, peripheral side: what the board does between two
//! stretches of execution.
//!
//! board.zig is the list of what the board is made of. This is the other
//! half: the order the blocks are stepped in, and where an event goes once
//! one of them has raised it. The two are separated because the order here
//! is load-bearing in a way the field list is not, the same reason the bus
//! order sits in wiring.zig rather than beside the blocks it attaches.
const chip = @import("ra8_chip");

const core_clock = @import("core_clock.zig");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;

const agt_sched = @import("ra8_chip").periph.agt.sched;
const Board = @import("board.zig").Board;
const board_hx6538 = @import("vendor/himax/grove_vision_ai_v2.zig");
const event_sink = @import("event_sink.zig");
const fpb_ra4t1 = @import("vendor/renesas/fpb_ra4t1.zig");
const gpt_sched = @import("ra8_chip").periph.gpt.sched;
const pin_irq = @import("ra8_chip").periph.icu.pin_irq;

/// Whether a sleeping core may run to the next queued event: src/board/quiet_due.zig.
pub const quiet_due = @import("quiet_due.zig");
const reset = @import("ra8_chip").periph.reset;
const rtc_sched = @import("ra8_chip").periph.rtc.sched;

/// Cycles at the time base's rate until the next event on the board's
/// queue, zero when nothing is queued or it is already due. The run loop
/// weighs this when it sizes a stretch (src/interfaces/cli/zig/run.zig).
pub fn cyclesToDue(context: *anyopaque) u64 {
    const board: *const Board = @ptrCast(@alignCast(context));
    const at = board.time.queue.next() orelse return 0;
    return board.time.base.cyclesUntil(at);
}

pub fn observation(self: *Board) event_sink.Observation {
    const panel = self.asks.attached_eink orelse &self.panel;
    const dirty = panel.latestRefresh();
    return .{
        .wdt_underflows = self.watchdog.underflows,
        .wdt_refresh_errors = self.watchdog.early,
        .iwdt_underflows = self.heartbeat.underflows,
        .glcdc_frames = self.display.system.frames,
        .glcdc_width = self.display.panelWidth(),
        .glcdc_height = self.display.panelHeight(),
        .eink_refreshes = panel.refreshes,
        .eink_width = panel.planes.geometry.width,
        .eink_height = panel.planes.geometry.height,
        .eink_dirty = .{
            .x = dirty.x,
            .y = dirty.y,
            .width = dirty.width,
            .height = dirty.height,
        },
    };
}

/// The watchdog counts, a block with an event due raises it into the event
/// links, a reset the watchdog asked for is recorded as the boot cause, then
/// any line still latched re-pends. The controller picks straight
/// afterwards, so an interrupt raised here is entered in the same boundary
/// rather than a chunk later.
pub fn tick(self: *Board, core: Guest, instructions: u32) !void {
    return tickFrom(self, core, instructions, .cpu0);
}

pub fn tickFrom(self: *Board, core: Guest, instructions: u32, issuer: chip.periph.registry.Issuer) !void {
    const mode = self.desc().memory.resolvedPeripherals();
    if (mode == .none or mode == .hx6538) return tickBare(self, core, instructions, issuer);
    if (mode == .ra4t1) return fpb_ra4t1.tick(self, core, instructions, issuer);
    if (self.event_sink) |sink| sink.observeFn(sink.context, issuer, self.time.base.now(), observation(self));
    const before_ns = self.time.base.now();
    self.time.base.advance(instructions);
    try tickTimers(self, mode, before_ns);
    notifyFrameTaps(self);
    core_clock.retune(self);
    try takeResetRequestsFrom(self, core, issuer);
    for (self.serial.channels) |channel| {
        if (channel.device) |device| device.tick(&self.pins);
    }
    self.console_input.poll(&self.serial);
    if (mode == .ra8_dual) pollDualInputs(self);
    try raisePinEdges(self, core);
    try drainEvents(self, core, mode);
    try irqSource(self, .cpu0).repend(&core, self.desc().primary().scs.irq_lines);
    if (self.cpu1) |second| try irqSource(self, .cpu1).repend(&second, cpu1IrqLines(self));
    // Drains after the reset request may have latched a line again.
    if (self.reboot) |pending| if (pending.requested) clearIrqLatches(self);
    if (self.run_hook) |hook| hook.boundaryFn(hook.context, self.time.base.now());
}

fn tickTimers(self: *Board, mode: chip.core.machine.memory.PeripheralSet, before_ns: u64) !void {
    const now = self.time.base.now();
    const elapsed_ns = now - before_ns;
    self.watchdog.tickFor(elapsed_ns);
    self.heartbeat.tickFor(elapsed_ns);
    try self.watchdog.arm(&self.time.queue, now);
    try self.heartbeat.arm(&self.time.queue, now);
    self.lowpower.tick();
    self.clock.tickFor(elapsed_ns);
    try rtc_sched.arm(&self.clock, &self.time.queue, now);
    agt_sched.tickFor(&self.interval, before_ns, now);
    try agt_sched.arm(&self.interval, &self.time.queue, now);
    gpt_sched.tickFor(&self.pwm, before_ns, now);
    self.trace.tick();
    self.usb.tick();
    if (mode != .ra8_dual) return;
    self.microphone.tick();
    self.ptp.tick(elapsed_ns);
    self.rswitch.tick();
    if (self.display.output.vsync) |*frame| {
        if (frame.tick(now)) {
            self.display.frameEvent();
            frame.notify(now);
        }
    }
}

fn pollDualInputs(self: *Board) void {
    self.touch_input.poll(&self.wire.panel, &self.pins);
    self.input_script.dispatchObserved(
        self.time.base.now(),
        &self.wire.panel,
        &self.pins,
        &self.touch_input,
        self.input_landing,
    );
}

fn drainEvents(self: *Board, core: Guest, mode: chip.core.machine.memory.PeripheralSet) !void {
    try drain(self, core, self.serial.dueEvents());
    try drain(self, core, self.lowpower.dueEvents());
    try drain(self, core, self.can.dueEvents());
    try drain(self, core, self.clock.dueEvents());
    try drain(self, core, self.interval.dueEvents());
    try drain(self, core, self.pwm.dueEvents());
    try drain(self, core, self.adc.dueEvents());
    try drain(self, core, self.dma.dueEvents());
    try drain(self, core, self.usb.dueEvents());
    try drain(self, core, self.links.takeEvents());
    if (mode != .ra8_dual) return;
    try drain(self, core, self.mailbox.dueEvents());
    try drain(self, core, self.npu.dueEvents());
}

fn tickBare(self: *Board, core: Guest, instructions: u32, issuer: chip.periph.registry.Issuer) !void {
    if (self.event_sink) |sink| sink.observeFn(sink.context, issuer, self.time.base.now(), observation(self));
    const before_ns = self.time.base.now();
    self.time.base.advance(instructions);
    if (self.desc().peripheralsKind() == .hx6538) {
        try board_hx6538.tick(
            &self.hx,
            &self.time.base,
            &self.console_input,
            core,
            self.cpu1,
            self.desc().primary().scs.irq_lines,
            cpu1IrqLines(self),
            before_ns,
        );
    }
    self.trace.tick();
    notifyFrameTaps(self);
    try takeResetRequestsFrom(self, core, issuer);
    try irqSource(self, .cpu0).repend(&core, self.desc().primary().scs.irq_lines);
    if (self.cpu1) |second| try irqSource(self, .cpu1).repend(&second, cpu1IrqLines(self));
    if (self.reboot) |pending| if (pending.requested) clearIrqLatches(self);
    if (self.run_hook) |hook| hook.boundaryFn(hook.context, self.time.base.now());
}

pub fn notifyFrameTaps(self: *Board) void {
    if (self.frame_tap) |tap| {
        if (!self.frame_taps.contains(tap)) tap.afterBoundary(self.time.base.now());
    }
    self.frame_taps.afterBoundary(self.time.base.now());
}

/// Vendor-neutral external interrupt source for `issuer` on this board.
pub fn irqSource(self: *Board, issuer: chip.periph.registry.Issuer) chip.periph.irq_source.IrqSource {
    const slot: usize = if (issuer == .cpu1) 1 else 0;
    if (self.irq_override[slot]) |src| return src;
    return switch (self.desc().memory.resolvedPeripherals()) {
        .ra4t1 => self.ra4t1.icu.irqSource(),
        .hx6538 => self.hx.direct_irqs[slot].irqSource(),
        else => self.events.irqSourceFor(issuer),
    };
}

pub fn clearIrqLatches(self: *Board) void {
    if (self.desc().memory.resolvedPeripherals() == .ra4t1) {
        self.ra4t1.icu.irqSource().clearLatches();
    } else {
        self.events.clearLatches();
    }
    if (self.irq_override[0]) |src| src.clearLatches();
    if (self.irq_override[1]) |src| src.clearLatches();
    if (self.desc().peripheralsKind() == .hx6538) {
        for (&self.hx.direct_irqs) |*lines| {
            lines.irqSource().clearLatches();
        }
    }
}

fn cpu1IrqLines(self: *const Board) u16 {
    return if (self.desc().core(.cpu1)) |c| c.scs.irq_lines else 0;
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
    for (events.constSlice()) |event| {
        try raise(self, core, event);
    }
}

/// One event, offered to all three consumers of one. The links first, and
/// they see EVERY event, not just the four the ELC generates: an event fans
/// out to the ICU and the ELC at once, and a link conducts without consuming
/// it. Then the transfer controller, before the core: a DTCE slot belongs to
/// the DTC until its descriptor runs out.
pub fn raise(self: *Board, core: Guest, event: u16) !void {
    if (!self.desc().memory.attach_ra8_blocks or self.irq_override[0] != null) {
        return irqSource(self, .cpu0).raise(&core, self.desc().primary().scs.irq_lines, event);
    }
    _ = self.links.conduct(event);
    // INTSELR hands the event to CPU1's ICU. With no CPU1 attached it stays
    // CPU0's, which keeps a single-core run what it was.
    if (self.events.select.coreFor(event) == .cpu1) {
        if (self.cpu1) |second| return raiseToSecond(self, second, event);
    }
    if (self.transfers.activate(core.asInitiator(.dtc0), &self.events, event)) |moved| {
        if (!moved.interrupt) return;
    }
    try irqSource(self, .cpu0).raise(&core, self.desc().primary().scs.irq_lines, event);
}

fn raiseToSecond(self: *Board, second: Guest, event: u16) !void {
    if (self.transfers1.activate(second.asInitiator(.dtc1), &self.events, event)) |moved| {
        if (!moved.interrupt) return;
    }
    try irqSource(self, .cpu1).raise(&second, cpu1IrqLines(self), event);
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
    return takeResetRequestsFrom(self, core, .cpu0);
}

pub fn takeResetRequestsFrom(self: *Board, core: anytype, issuer: chip.periph.registry.Issuer) !void {
    if (self.watchdog.reset_requested) {
        self.watchdog.reset_requested = false;
        if (self.run_hook) |hook| hook.resetFn(hook.context, .watchdog, self.time.base.now());
        resetForFrom(self, .watchdog, issuer);
    }
    if (self.heartbeat.reset_requested) {
        self.heartbeat.reset_requested = false;
        if (self.run_hook) |hook| hook.resetFn(hook.context, .iwdt, self.time.base.now());
        resetForFrom(self, .iwdt, issuer);
    }
    if (issuer == .cpu1) return;
    try self.clears.apply(core);
    if (self.desc().memory.resolvedPeripherals() != .ra4t1) try self.caches.poll(core);
    try self.regions.poll(core);
    if (try self.control.poll(core)) resetForFrom(self, .software, issuer);
}

/// Latch one cause and ask for the reboot. The interrupt latches go down on
/// the way past: a line still pending would be entered before the firmware
/// coming back up has put its vector table back.
pub fn resetFor(self: *Board, source: reset.Source) void {
    resetForFrom(self, source, .cpu0);
}

pub fn resetForFrom(self: *Board, source: reset.Source, issuer: chip.periph.registry.Issuer) void {
    if (self.event_sink) |sink| sink.resetFn(sink.context, issuer, source, self.time.base.now());
    self.causes.request(source);
    clearIrqLatches(self);
    self.second_core.reset();
    if (self.desc().peripheralsKind() == .hx6538) self.hx.reset();
    if (self.reboot) |pending| pending.requested = true;
}

/// The board as a Tick for the core's run loop.
pub fn tickThunk(context: *anyopaque, core: Guest, instructions: u32) anyerror!void {
    const board: *Board = @ptrCast(@alignCast(context));
    return board.tick(core, instructions);
}
