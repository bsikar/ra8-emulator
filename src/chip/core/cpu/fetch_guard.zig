//! A check the core makes before each instruction it is about to fetch.
//!
//! The retire listener only hears about an instruction once it has run.
//! `--stop-on-undefined` has to end a run BEFORE the site executes, so the
//! dumps beside its report show the machine on the way in. The guard answers whether the
//! instruction at an address may run; a held one ends the stretch with the
//! PC still on it.
pub const FetchGuard = struct {
    context: *anyopaque,
    holdsFn: *const fn (context: *anyopaque, address: u32) bool,

    /// Should the instruction at `address` be held back?
    pub fn holds(self: FetchGuard, address: u32) bool {
        return self.holdsFn(self.context, address);
    }
};
