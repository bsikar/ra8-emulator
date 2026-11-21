//! What CPU1 takes from the board it sits on (RA8EMU-1012). CPU1's
//! bring-up belongs to the chip; the board only hands over this wiring:
//! the bus CPU1's stores reach, the divider that sizes its turns, the
//! reboot latch and the CPU1 control page that release it, the slot the
//! board routes CPU1's events through, and two hooks back into the board.
const CoreWindows = @import("../windows.zig").CoreWindows;
const cpu_ctrl = @import("../../periph/cpu_ctrl.zig");
const Guest = @import("../cpu/memory/guest/guest.zig").Guest;
const machine = @import("../machine/machine.zig");
const part = @import("../part/part.zig");
const rate = @import("../rate.zig");
const reboot = @import("../reboot.zig");
const registry = @import("../../periph/registry.zig");

/// Pluggable secondary-core hold/release control and initial VTOR provider.
pub const Release = struct {
    context: *const anyopaque,
    runningFn: *const fn (context: *const anyopaque) bool,
    initvtorFn: *const fn (context: *const anyopaque) u32,

    pub fn running(self: Release) bool {
        return self.runningFn(self.context);
    }

    pub fn initvtor(self: Release) u32 {
        return self.initvtorFn(self.context);
    }
};

pub const Wiring = struct {
    /// The shared peripheral bus CPU1's stores fall through to.
    bus: *registry.Bus,
    /// SCKDIVCR2, which sizes CPU1's turns against CPU0's.
    dividers: *const u16,
    /// Fixed core clock ratio (`cpu1_hz : cpu0_hz`), overriding `dividers` when set.
    clock_ratio: ?rate.Ratio = null,
    /// The board's reboot latch, read each time CPU1 asks whether it is
    /// held, since the run may attach it after CPU1 opens.
    reboot: *const ?*reboot.Reboot,
    /// The CPU1 control page (CPU1ACTCSR, CPU1INITVTOR) that releases it.
    release: *const cpu_ctrl.CpuCtrl,
    /// Optional machine-specific release/reset controller (overriding `release`).
    custom_release: ?Release = null,
    /// Hold CPU1 immediately at initial cold open when gated.
    initial_hold: bool = false,
    /// Re-hold CPU1 whenever the controller gates or asserts reset.
    hold_while_gated: bool = false,
    /// Where the board looks for CPU1's store, so INTSELR events reach
    /// CPU1's NVIC and DTC1.
    cpu1: *?Guest,
    /// The core in slot 1, or null when the machine has no second core.
    core: ?machine.Core = part.cores.cpu1,
    context: *anyopaque,
    /// Seeds a core's own PPB windows with their reset values.
    primeFn: *const fn (context: *anyopaque, memory: Guest, windows: CoreWindows) anyerror!void,
    /// Takes a SYSRESETREQ from CPU1, the part's one software reset.
    resetFn: *const fn (context: *anyopaque) void,

    pub fn prime(self: Wiring, memory: Guest, windows: CoreWindows) !void {
        return self.primeFn(self.context, memory, windows);
    }

    pub fn requestReset(self: Wiring) void {
        self.resetFn(self.context);
    }

    pub fn releaseRunning(self: Wiring) bool {
        if (self.custom_release) |rel| return rel.running();
        return self.release.running();
    }

    pub fn releaseInitVtor(self: Wiring) u32 {
        if (self.custom_release) |rel| return rel.initvtor();
        return self.release.initvtor;
    }
};
