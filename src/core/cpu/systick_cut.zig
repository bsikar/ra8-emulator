//! A store that arms SysTick ends the stretch in flight (RA8EMU-464).
//!
//! The Zig core's twin of src/core/systick_hook.zig. A `--cpu zig` run cuts
//! each stretch from the SysTick period armed when the stretch begins, and
//! at reset nothing is armed, so the first stretch is a whole boundary wide.
//! `ra8_time_init` arms SysTick inside it, and the periods that stretch then
//! covers collapse into one pend: blink_hal ran 5 ms behind Unicorn from
//! boot that way. Seeing the store, and ending the stretch after the
//! instruction that made it, keeps the next boundary cut from the period the
//! firmware just armed. src/periph/systick_arm.zig holds the rule; this
//! only finds the timer a store lands on and latches the cut.
const std = @import("std");
const bus = @import("bus.zig");
const memmap = @import("../memmap.zig");
const clocks = @import("../../periph/clocks.zig");
const systick_arm = @import("../../periph/systick_arm.zig");

/// The SysTick timers a core's stores can arm, and the cut they latch.
pub const Cut = struct {
    /// The Secure timer and the Non-secure one at the alias; null skips one.
    clocks: [2]?*clocks.Clocks = .{ null, null },
    /// Set by a store that re-sized a period; read by `Cpu.run` after every
    /// instruction and taken by the stretch loop.
    fired: bool = false,

    /// Look at a store before it lands: the rule needs the two registers as
    /// they stand. Only word stores count, as on the Unicorn hook.
    pub fn see(self: *Cut, memory: bus.Bus, address: u32, bytes: []const u8) bus.Error!void {
        if (bytes.len != 4) return;
        for (self.clocks) |slot| {
            const clock = slot orelse continue;
            const offset = offsetOf(clock.words, address) orelse continue;
            const word = std.mem.readInt(u32, bytes[0..4], .little);
            const csr = try memory.readWord(clock.words.csr);
            const rvr = try memory.readWord(clock.words.rvr);
            if (systick_arm.observe(offset, word, csr, rvr) == .none) continue;
            clock.armed();
            self.fired = true;
        }
    }

    /// Take the cut, clearing the clocks' own latches with it, so one
    /// store ends one stretch.
    pub fn take(self: *Cut) bool {
        const hit = self.fired;
        self.fired = false;
        for (self.clocks) |slot| if (slot) |clock| {
            _ = clock.took();
        };
        return hit;
    }
};

/// The register a store lands on, as the rule's normal-window offset.
fn offsetOf(words: clocks.Words, address: u32) ?u32 {
    if (address == words.csr) return memmap.syst.csr;
    if (address == words.rvr) return memmap.syst.rvr;
    return null;
}
