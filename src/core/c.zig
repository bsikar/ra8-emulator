//! The only C surface in the rewrite: Capstone.
//!
//! Everything above this file is native Zig with native Zig types. Nothing
//! here is exported back to C, and the emulator keeps no C ABI of its own;
//! this declaration exists only for the Capstone parity oracle
//! (src/debug/capstone_ref.zig); the run path's disassembler is our own since
//! RA8EMU-249. It goes with the oracle in RA8EMU-692.
pub const cs = @cImport({
    @cInclude("capstone/capstone.h");
});
