//! Thread switches as a trace, from stores to ThreadX's current-thread
//! pointer (RA8EMU-222).
//!
//! ThreadX names the running thread in `_tx_thread_current_ptr`: the
//! scheduler writes the next thread's control block there as it switches,
//! and zero while no thread runs. A store of a new value is a switch, a
//! store of zero is idle, and a store of the value already there is no
//! switch at all, so it is not recorded.
//!
//! This file knows nothing about Unicorn or the Zig core. Whatever sees the
//! store hands it the core, the virtual time and the value; the hook that
//! does so is RA8EMU-221.
pub const limits = struct {
    /// Events kept, oldest first. A run that switches more than this keeps
    /// the opening and counts the rest, so the memory a trace costs is
    /// fixed however long the run goes.
    pub const kept: usize = 256;
    /// Cores the RA8 parts have: CPU0 and CPU1.
    pub const cores: usize = 2;
};

pub const Kind = enum { switch_to, idle };

/// One change of the running thread on one core.
pub const Event = struct {
    /// Virtual time as the store landed, in the run's timebase.
    when: u64,
    core: u1,
    kind: Kind,
    /// The control block now running; zero for idle.
    thread: u32,
};

pub const Trace = struct {
    events: [limits.kept]Event = undefined,
    len: usize = 0,
    /// Events past `limits.kept`, counted and not kept.
    dropped: usize = 0,
    /// What each core last stored, so a repeat is not taken for a switch.
    current: [limits.cores]?u32 = .{ null, null },

    /// Take one store to the current-thread pointer.
    pub fn store(self: *Trace, core: u1, when: u64, value: u32) void {
        if (self.current[core]) |was| {
            if (was == value) return;
        }
        self.current[core] = value;
        const one = Event{
            .when = when,
            .core = core,
            .kind = if (value == 0) .idle else .switch_to,
            .thread = value,
        };
        if (self.len == limits.kept) {
            self.dropped += 1;
            return;
        }
        self.events[self.len] = one;
        self.len += 1;
    }

    /// The events kept, oldest first.
    pub fn list(self: *const Trace) []const Event {
        return self.events[0..self.len];
    }

    /// The events kept for one core, written into the caller's buffer.
    pub fn onCore(self: *const Trace, core: u1, into: []Event) []const Event {
        var count: usize = 0;
        for (self.list()) |one| {
            if (one.core != core) continue;
            if (count == into.len) break;
            into[count] = one;
            count += 1;
        }
        return into[0..count];
    }
};
