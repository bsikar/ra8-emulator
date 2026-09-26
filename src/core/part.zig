//! Which part a run models.
//!
//! The RA8P1 and the RA8D2 share a register map and a memory map, so one set
//! of peripheral models serves both and an RA8P1-linked ELF boots exactly as
//! an RA8D2 one does. The one difference is that the RA8P1 carries an Arm
//! Ethos-U55 micro-NPU and the RA8D2 does not, so the choice of part decides
//! whether the NPU window answers at all. Everything else on the board is
//! identical, which is why this is an enum and not a table.
const std = @import("std");

pub const Part = enum {
    ra8d2,
    ra8p1,

    /// The part named on the command line, or null for a name this emulator
    /// does not model. Nothing is guessed: an unknown name is refused rather
    /// than quietly falling back to the default part.
    pub fn parse(text: []const u8) ?Part {
        if (std.mem.eql(u8, text, "ra8d2")) return .ra8d2;
        if (std.mem.eql(u8, text, "ra8p1")) return .ra8p1;
        return null;
    }

    pub fn label(self: Part) []const u8 {
        return switch (self) {
            .ra8d2 => "RA8D2",
            .ra8p1 => "RA8P1",
        };
    }

    /// Whether this part has the Ethos-U55 NPU behind 0x4014_0000.
    pub fn hasNpu(self: Part) bool {
        return self == .ra8p1;
    }
};
