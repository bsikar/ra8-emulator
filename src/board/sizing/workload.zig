//! The synthetic weight-streaming workload a sizing sweep runs
//! (RA8EMU-645). A model's weights stream out of OSPI flash once per
//! inference while its activations go in and out of SDRAM. It stands in for
//! the translation images until they exist to be run instead.
pub const kib: u64 = 1024;
pub const mib: u64 = 1024 * kib;

pub const Synthetic = struct {
    /// Weight bytes in OSPI flash, each read once per pass.
    weights_bytes: u64 = 16 * mib,
    /// Activation bytes in SDRAM, each read and written once per pass.
    activations_bytes: u64 = 2 * mib,
    /// Inferences run back to back.
    passes: u32 = 1,
    /// Weight bytes the NPU fetches ahead of the compute that uses them.
    chunk_bytes: u64 = 64 * kib,
    /// The Ethos-U55's clock and MAC array width.
    npu_hz: u64 = 500_000_000,
    npu_macs_per_cycle: u64 = 256,
    /// MACs each weight byte feeds (its reuse across one layer's outputs).
    macs_per_weight_byte: u64 = 64,
    /// The CPU's clock and its pre- and post-processing per pass.
    cpu_hz: u64 = 1_000_000_000,
    cpu_cycles_per_pass: u64 = 2_000_000,

    pub fn validate(self: Synthetic) Error!void {
        if (self.weights_bytes == 0 or self.weights_bytes > 256 * mib) return Error.BadWeights;
        if (self.activations_bytes > 128 * mib) return Error.BadActivations;
        if (self.passes == 0) return Error.BadPasses;
        if (self.chunk_bytes == 0 or self.npu_hz == 0 or self.npu_macs_per_cycle == 0 or self.cpu_hz == 0) {
            return Error.BadRate;
        }
    }

    /// How many weight chunks one pass streams.
    pub fn chunks(self: Synthetic) u64 {
        return (self.weights_bytes + self.chunk_bytes - 1) / self.chunk_bytes;
    }
};

pub const Error = error{ BadWeights, BadActivations, BadPasses, BadRate };
