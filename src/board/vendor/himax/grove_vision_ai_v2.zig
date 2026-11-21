//! Himax HX6538 (Seeed Grove Vision AI V2) board attachment, timer/UART/mailbox ticking, and direct IRQ routing.
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const hx_periph = @import("ra8_chip").vendor.himax.hx6538;
const irq_source = @import("ra8_chip").periph.irq_source;
const Machine = @import("ra8_chip").core.machine.Machine;
const registry = @import("ra8_chip").periph.registry;
const sci_input = @import("ra8_chip").periph.sci.input;
const sci_line = @import("ra8_chip").periph.sci.line;
const second_wiring = @import("ra8_chip").core.second.wiring;
const timebase = @import("ra8_chip").periph.timebase;

pub const timer_hz: u64 = 24_000_000;

pub const State = struct {
    periph: hx_periph.Periph = .{},
    direct_irqs: [2]irq_source.DirectLines = @splat(.{}),
    timer_rem: u64 = 0,

    pub fn seed(self: *State, line: *sci_line.Line) void {
        self.* = .{};
        self.periph.uarts.channels[0].console = line;
        for (&self.direct_irqs) |*lines| {
            configureLines(lines);
        }
    }

    pub fn release(self: *const State) second_wiring.Release {
        return .{
            .context = &self.periph.scu,
            .runningFn = scuRunningThunk,
            .initvtorFn = scuInitVtorThunk,
        };
    }

    pub fn reset(self: *State) void {
        self.periph.scu.cm55s_state = 0;
        self.periph.scu.cm55s_cpuwait = 1;
        for (&self.direct_irqs) |*lines| {
            lines.irqSource().clearLatches();
        }
    }

    pub fn wireCpu1(self: *const State, machine: *const Machine, wiring: *second_wiring.Wiring) void {
        wiring.clock_ratio = .{ .num = machine.cpu1_hz, .den = machine.cpu0_hz };
        wiring.custom_release = self.release();
        wiring.initial_hold = true;
        wiring.hold_while_gated = true;
    }
};

fn configureLines(lines: *irq_source.DirectLines) void {
    lines.setLevelTriggered(hx_periph.irqs.mailbox, true);
    for (hx_periph.timer.irqs) |line| {
        lines.setLevelTriggered(line, true);
    }
    for (hx_periph.uart.irqs) |line| {
        lines.setLevelTriggered(line, true);
    }
}

pub fn attachBlocks(self: *State, bus: *registry.Bus) !void {
    try bus.add(self.periph.scu.aonBlock());
    try bus.add(self.periph.scu.sbBlock());
    try bus.add(self.periph.scu.lscBlock());
    try bus.add(self.periph.mailbox.block());
    for (&self.periph.uarts.channels, 0..) |*ch, idx| {
        try bus.add(ch.block(idx));
    }
    for (&self.periph.timers.channels, 0..) |*ch, idx| {
        try bus.add(ch.block(idx));
    }
}

pub fn tick(
    self: *State,
    time_base: *timebase.TimeBase,
    console_input: *sci_input.Input,
    core0: Guest,
    core1: ?Guest,
    irq0_lines: u16,
    irq1_lines: u16,
    before_ns: u64,
) !void {
    const elapsed_ns = time_base.now() - before_ns;
    const scaled = elapsed_ns * timer_hz + self.timer_rem;
    self.timer_rem = scaled % timebase.ns_per_s;
    self.periph.timers.tick(scaled / timebase.ns_per_s);
    console_input.pollPush(&self.periph.uarts.channels[0]);
    try syncLine(&self.direct_irqs[0], core0, irq0_lines, hx_periph.irqs.mailbox, self.periph.mailbox.pendingM());
    if (core1) |second| {
        try syncLine(
            &self.direct_irqs[1],
            second,
            irq1_lines,
            hx_periph.irqs.mailbox,
            self.periph.mailbox.pendingS(),
        );
    }
    try syncSharedIrqs(self, core0, core1, irq0_lines, irq1_lines);
}

fn syncSharedIrqs(
    self: *State,
    core0: Guest,
    core1: ?Guest,
    irq0_lines: u16,
    irq1_lines: u16,
) !void {
    for (&self.periph.timers.channels, 0..) |*ch, idx| {
        const asserted = ch.irqAsserted();
        const line = hx_periph.timer.irqs[idx];
        try syncLine(&self.direct_irqs[0], core0, irq0_lines, line, asserted);
        if (core1) |second| try syncLine(&self.direct_irqs[1], second, irq1_lines, line, asserted);
    }
    for (&self.periph.uarts.channels, 0..) |*ch, idx| {
        const asserted = ch.irqAsserted();
        const line = hx_periph.uart.irqs[idx];
        try syncLine(&self.direct_irqs[0], core0, irq0_lines, line, asserted);
        if (core1) |second| try syncLine(&self.direct_irqs[1], second, irq1_lines, line, asserted);
    }
}

fn syncLine(
    lines: *irq_source.DirectLines,
    guest: Guest,
    irq_lines: u16,
    line: u16,
    asserted: bool,
) !void {
    const src = lines.irqSource();
    if (asserted) {
        try src.raise(&guest, irq_lines, line);
    } else {
        src.acknowledge(line);
    }
}

fn scuRunningThunk(context: *const anyopaque) bool {
    const unit: *const hx_periph.scu.Scu = @ptrCast(@alignCast(context));
    return unit.cm55sRunning();
}

fn scuInitVtorThunk(context: *const anyopaque) u32 {
    const unit: *const hx_periph.scu.Scu = @ptrCast(@alignCast(context));
    return unit.cm55s_initsvtor;
}
