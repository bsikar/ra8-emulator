//! A store that arms SysTick ends the stretch in flight (RA8EMU-464).
//!
//! A `--cpu zig` run cuts each stretch from the SysTick period armed when
//! the stretch begins, and at reset nothing is armed, so the first stretch
//! is a whole boundary wide.
//! `ra8_time_init` arms SysTick inside it, and the periods that stretch then
//! covers collapse into one pend: blink_hal ran 5 ms behind the part from
//! boot that way. Seeing the store, and ending the stretch after the
//! instruction that made it, keeps the next boundary cut from the period the
//! firmware just armed. src/chip/periph/systick_arm.zig holds the rule; this
//! only finds the timer a store lands on and latches the cut.
const std = @import("std");
const bus = @import("bus.zig");
const memmap = @import("../memmap.zig");
const clocks = @import("../../periph/clocks.zig");
const systick_arm = @import("../../periph/systick_arm.zig");
const banked = @import("../banked.zig");

/// The timer that caused a cut and its state before the instruction's stores.
pub const Pending = struct {
    bank: Bank = .secure,
    old_reload: u32 = 0,
    old_control: u8 = 0,
    old_current: u32 = 0,
    current_written: bool = false,

    pub const Bank = enum(u8) { secure, non_secure };

    pub fn valid(self: Pending) bool {
        if (self.old_reload > clocks.counter_mask or self.old_current > clocks.counter_mask) return false;
        if (self.old_control & ~@as(u8, clocks.csr_enable | clocks.csr_tickint) != 0) return false;
        if (self.old_reload != 0 and self.old_control & clocks.csr_enable == 0) return false;
        return self.current_written or self.old_current == 0;
    }
};

const Prior = struct { reload: u32, control: u8, current: u32, current_written: bool = false };

/// The SysTick timers a core's stores can arm, and the cut they latch.
pub const Cut = struct {
    /// The Secure timer and the Non-secure one at the alias; null skips one.
    clocks: [2]?*clocks.Clocks = .{ null, null },
    /// The core using an unlanded bus view; null means addresses are landed.
    requester: ?*const banked.Banked = null,
    /// CPU slot count identifies all stores made by one instruction.
    instruction: ?*const u64 = null,
    /// Set by a store that re-sized a period; read by `Cpu.run` after every
    /// instruction and taken by the stretch loop.
    fired: bool = false,
    pending: ?Pending = null,
    seen: [2]?Prior = .{ null, null },
    seen_slot: ?u64 = null,

    /// Look at a store before it lands: the rule needs the two registers as
    /// they stand. Only word stores count.
    pub fn see(self: *Cut, memory: bus.Bus, address: u32, bytes: []const u8) bus.Error!void {
        if (bytes.len != 4) return;
        if (self.instruction) |slot| {
            if (self.seen_slot == null or self.seen_slot.? != slot.*) {
                self.seen = .{ null, null };
                self.seen_slot = slot.*;
            }
        }
        const ns_normal = if (self.requester) |state|
            state.current == .non_secure and (address == memmap.syst.csr or address == memmap.syst.rvr or address == memmap.syst.cvr)
        else
            false;
        const landed = if (ns_normal) address + 0x2_0000 else address;
        for (self.clocks, 0..) |slot, index| {
            const clock = slot orelse continue;
            const offset = offsetOf(clock.words, landed) orelse continue;
            const word = std.mem.readInt(u32, bytes[0..4], .little);
            const csr = try memory.readWord(if (ns_normal) memmap.syst.csr else clock.words.csr);
            const rvr = try memory.readWord(if (ns_normal) memmap.syst.rvr else clock.words.rvr);
            if (self.seen[index] == null) self.seen[index] = .{
                .reload = if (csr & clocks.csr_enable != 0) rvr & clocks.counter_mask else 0,
                .control = @intCast(csr & (clocks.csr_enable | clocks.csr_tickint)),
                .current = (try memory.readWord(if (ns_normal) memmap.syst.cvr else clock.words.cvr)) & clocks.counter_mask,
            };
            const prior = &self.seen[index].?;
            const bank: Pending.Bank = if (index == 0) .secure else .non_secure;
            if (offset == memmap.syst.cvr) {
                prior.current_written = true;
                if (self.pending) |*pending| if (pending.bank == bank) {
                    pending.old_current = prior.current;
                    pending.current_written = true;
                };
                continue;
            }
            if (systick_arm.observe(offset, word, csr, rvr) == .none) continue;
            clock.armed();
            self.fired = true;
            self.pending = .{
                .bank = bank,
                .old_reload = prior.reload,
                .old_control = prior.control,
                .old_current = if (prior.current_written) prior.current else 0,
                .current_written = prior.current_written,
            };
        }
    }

    /// Take the cut, clearing the clocks' own latches with it, so one
    /// store ends one stretch.
    pub fn take(self: *Cut) bool {
        return self.takePending() != null;
    }

    pub fn takePending(self: *Cut) ?Pending {
        const info = if (self.fired) self.pending else null;
        self.fired = false;
        self.pending = null;
        self.seen = .{ null, null };
        self.seen_slot = null;
        for (self.clocks) |slot| if (slot) |clock| {
            _ = clock.took();
        };
        return info;
    }
};

/// The register a store lands on, as the rule's normal-window offset.
fn offsetOf(words: clocks.Words, address: u32) ?u32 {
    if (address == words.csr) return memmap.syst.csr;
    if (address == words.rvr) return memmap.syst.rvr;
    if (address == words.cvr) return memmap.syst.cvr;
    return null;
}
