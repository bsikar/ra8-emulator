//! The board: the peripheral bus and every block that answers on it.
//!
//! This is the part of the machine that is not the CPU. main.zig owns the
//! wiring of a run (read an ELF, reset, run, print), the engine owns the CPU,
//! and everything that lives behind an address in the peripheral window is
//! held here so neither of the other two has to know the list. The end-of-run
//! narration that reads this state lives next door in report.zig.
const std = @import("std");

const engine = @import("../core/engine.zig");
const periph = @import("../periph/registry.zig");
const bkup = @import("../periph/bkup.zig");
const cac = @import("../periph/cac.zig");
const crc = @import("../periph/crc.zig");
const doc = @import("../periph/doc.zig");
const gpio = @import("../periph/gpio.zig");
const icu = @import("../periph/icu.zig");
const lvd = @import("../periph/lvd.zig");
const mstp = @import("../periph/mstp.zig");
const prcr = @import("../periph/prcr.zig");
const reset = @import("../periph/reset.zig");
const sci = @import("../periph/sci.zig");
const wdt = @import("../periph/wdt.zig");

pub const Board = struct {
    bus: periph.Bus,
    modules: mstp.Mstp = .{},
    events: icu.Icu,
    pins: gpio.Gpio,
    checksum: crc.Crc,
    dataops: doc.Doc,
    accuracy: cac.Cac,
    protection: prcr.Prcr,
    backup: bkup.Bkup,
    serial: sci.Sci,
    monitors: lvd.Lvd,
    watchdog: wdt.Wdt,
    causes: reset.Reset,

    pub fn init(allocator: std.mem.Allocator) Board {
        return .{
            .bus = periph.Bus.init(allocator),
            .events = icu.Icu.init(),
            .pins = gpio.Gpio.init(),
            .checksum = crc.Crc.init(),
            .dataops = doc.Doc.init(),
            .accuracy = cac.Cac.init(),
            .protection = prcr.Prcr.init(),
            // Patched in attach(): the backup file has to point at this
            // board's own protection model, not a copy of it.
            .backup = undefined,
            .serial = sci.Sci.init(),
            .monitors = lvd.Lvd.init(),
            .watchdog = wdt.Wdt.init(),
            .causes = reset.Reset.init(),
        };
    }

    pub fn deinit(self: *Board) void {
        self.bus.deinit();
    }

    /// Order matters. The module-stop shadow goes on first and then becomes
    /// the gate the rest of the bus is filtered through; PORT follows it
    /// because PORT has no module-stop bit on this part and has to answer
    /// regardless of MSTPCRx.
    pub fn attach(self: *Board, core: *engine.Engine) !void {
        try self.bus.add(self.modules.block());
        self.bus.gate = self.modules.gate();
        try self.bus.add(self.pins.block());
        try self.bus.add(self.checksum.block());
        try self.bus.add(self.dataops.block());
        try self.bus.add(self.accuracy.block());
        try self.bus.add(self.protection.block());
        self.backup = bkup.Bkup.init(&self.protection);
        try self.bus.add(self.backup.block());
        try self.bus.add(self.serial.block());
        try self.bus.add(self.events.block());
        try self.bus.add(self.monitors.statusBlock());
        try self.bus.add(self.monitors.controlBlock());
        try self.bus.add(self.monitors.filterBlock());
        try self.bus.add(self.watchdog.block());
        try self.bus.add(self.causes.statusBlock());
        try self.bus.add(self.causes.causeBlock());
        try core.attachPeriph(&self.bus);
    }

    /// The chunk boundary, peripheral side: the watchdog counts, a block with
    /// an event due raises it into the event links, a reset the watchdog asked
    /// for is recorded as the boot cause, then any line still latched
    /// re-pends. The controller picks straight afterwards, so an interrupt
    /// raised here is entered in the same boundary rather than a chunk later.
    pub fn tick(self: *Board, core: engine.Engine) !void {
        self.watchdog.tick();
        self.takeResetRequests();
        for (self.serial.dueEvents().constSlice()) |event| {
            try self.events.raise(core, event);
        }
        try self.events.repend(core);
    }

    /// A watchdog that has asked for a reset hands the request to the reset
    /// block once. Silicon reboots the part here; this tree has no reboot
    /// path yet, so the cause is latched and the run carries on, which is
    /// still the reading the firmware would get on the way back up.
    pub fn takeResetRequests(self: *Board) void {
        if (!self.watchdog.reset_requested) return;
        self.watchdog.reset_requested = false;
        self.causes.request(.watchdog);
    }

    pub fn ticker(self: *Board) engine.Tick {
        return .{ .context = self, .tickFn = tickThunk };
    }
};

fn tickThunk(context: *anyopaque, core: engine.Engine) anyerror!void {
    const board: *Board = @ptrCast(@alignCast(context));
    return board.tick(core);
}
