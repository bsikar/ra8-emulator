//! Who is driving a bus access: a CPU, the NPU's DMA, or untimed setup.
pub const Initiator = enum(u2) {
    none,
    cpu0,
    cpu1,
    ethos_u55,

    /// Which timed port this initiator's accesses are accounted on, if any.
    pub fn timedIndex(self: Initiator) ?usize {
        return switch (self) {
            .none => null,
            .cpu0 => 0,
            .cpu1 => 1,
            .ethos_u55 => 2,
        };
    }
};
