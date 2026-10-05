//! The only C surface in the rewrite: Capstone.
//!
//! Everything above this file is native Zig with native Zig types. Nothing
//! here is exported back to C, and the emulator keeps no C ABI of its own;
//! this declaration exists only because the error-path disassembler is a C
//! library. Capstone's goes when src/debug/disasm.zig moves to our own disassembler (RA8EMU-249).
pub const cs = @cImport({
    @cInclude("capstone/capstone.h");
});
