//! The only C surface in the rewrite: Unicorn and Capstone.
//!
//! Everything above this file is native Zig with native Zig types. Nothing
//! here is exported back to C, and no part of the emulator keeps a C ABI of
//! its own; these two declarations exist because the engine and the
//! disassembler are C libraries.
pub const uc = @cImport({
    @cInclude("unicorn/unicorn.h");
});

pub const cs = @cImport({
    @cInclude("capstone/capstone.h");
});
