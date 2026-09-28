//! How long a run lasts in modelled time, rather than in instructions.
//!
//! A budget counted in instructions cannot express "four seconds", because
//! the two are not a fixed ratio across this corpus. The model charges one
//! DWT cycle per instruction, and `ra8_time_init` arms SysTick at
//! `cpu_hz / 1000`, so instructions per modelled millisecond is whatever
//! clock the firmware brought the part up on. Measured over the images this
//! tree runs: `doc_demo`, `gpt_one_shot_demo` and `gpt_irq_demo` all reach
//! cpuclk0 and spend 1,000,000 instructions per SysTick period, while
//! `blink` never leaves the slower source it resets on and spends about
//! 8,400. One instruction number is therefore four seconds for one of them
//! and eight minutes for the other, and the suite that drives this asks for
//! its window in seconds (`HIL_PROBE_SECONDS`).
//!
//! So a timed run is bounded by the firmware's own tick instead. A SysTick
//! period is a millisecond because `ra8_time_init` armed it to be one; this
//! file counts the periods the clocks report and says when enough have gone
//! by. An image that never arms SysTick has no millisecond to count, and
//! nothing here fires: that run ends on its instruction budget, and the
//! verdict says which of the two ended it.
const std = @import("std");

pub const Deadline = struct {
    /// SysTick periods the run is allowed, which is milliseconds for as long
    /// as the firmware keeps SysTick armed at a kilohertz.
    periods: u64,
    /// Set when the run ended because modelled time ran out, which is what
    /// tells the report a deadline was honoured rather than a budget spent.
    reached: bool = false,

    /// Has enough modelled time gone by?
    ///
    /// `elapsed` is the clocks' own count of periods. Passing the deadline
    /// between two boundaries still counts: several periods can collapse
    /// into one stretch of execution, so the test is "at least", never
    /// "exactly", for the same reason the counter stop is.
    pub fn met(self: *Deadline, elapsed: u64) bool {
        if (elapsed < self.periods) return false;
        self.reached = true;
        return true;
    }
};
