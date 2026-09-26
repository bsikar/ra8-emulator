//! The MACI command sequencer: the byte stream that carries one extra-MRAM
//! command, and whether what arrived was a whole command.
//!
//! The command-issuing area at 0x4012_0000 is one port, not a register file.
//! A driver writes an opener byte, a count byte naming how many halfwords
//! follow, the halfwords themselves, and a trailer byte that starts
//! processing. The port never says anything back; the result shows up in
//! MSTATR. So this file holds only the collection: what state the stream is
//! in, what has been collected, and whether the trailer arrived on a stream
//! that was actually complete. Deciding what to do with the payload is the
//! controller's job and lives in mram.zig.
//!
//! Ported from board_periph_mram.c on dev, with two things that model does
//! not do.
//!
//! THE COUNT BYTE IS A COUNT. dev compares it against the literal 0x08 and
//! treats anything else as a stream to abandon, so the count is a magic
//! number rather than a length. Here the byte is kept as the number of
//! halfwords the command declared, and the controller checks the payload
//! that arrived against it.
//!
//! A SHORT COMMAND IS NOT A COMMAND. dev commits whatever halfwords turned
//! up before the trailer, so a driver that writes three of its eight and
//! then the trailer programs six bytes on dev and nothing at all on
//! silicon. Here the stream reports whether it is complete and the
//! controller refuses the rest.
const std = @import("std");

/// The opcodes this stream carries (HUM Ch 59.7.4, as named in the C model).
pub const opcode = struct {
    /// Program, for the extra-MRAM data area.
    pub const program: u8 = 0xE8;
    /// Configuration Set, for the OFS area.
    pub const config_set: u8 = 0x40;
    /// The trailer that starts processing.
    pub const final: u8 = 0xD0;
};

/// One command carries eight halfwords, which is what the driver's unit
/// write issues and the most this model will hold.
pub const max_halfwords: usize = 8;
pub const max_payload: usize = max_halfwords * 2;

/// Which opener started the stream. The controller programs both the same
/// way; the distinction is kept so the report can say which one ran.
pub const Kind = enum { program, config_set };

/// Where in a command the port is.
pub const State = enum {
    /// Nothing started: the next byte is an opener or it is ignored.
    idle,
    /// An opener arrived: the next byte is the halfword count.
    opened,
    /// The count arrived: halfwords are being collected until the trailer.
    collecting,
};

/// What a byte written to the port did to the stream.
pub const Step = enum {
    /// Nothing the controller has to act on.
    none,
    /// The trailer arrived: the controller should run the command.
    commit,
    /// A byte that is not the trailer arrived mid-stream, so the command
    /// was abandoned before it ran.
    abandoned,
};

pub const Sequencer = struct {
    state: State = .idle,
    kind: Kind = .program,
    /// Halfwords the count byte asked for.
    declared: usize = 0,
    payload: [max_payload]u8 = [_]u8{0} ** max_payload,
    len: usize = 0,
    /// A halfword arrived with no room left for it.
    overflowed: bool = false,

    pub fn reset(self: *Sequencer) void {
        self.* = .{};
    }

    /// The bytes collected so far, in the order they were written.
    pub fn bytes(self: *const Sequencer) []const u8 {
        return self.payload[0..self.len];
    }

    /// Whether what arrived is a whole command: a non-empty declaration, and
    /// exactly that many halfwords, none of them dropped.
    pub fn complete(self: *const Sequencer) bool {
        if (self.overflowed) return false;
        if (self.declared == 0) return false;
        return self.len == self.declared * 2;
    }

    /// One byte written to the command port.
    pub fn byteWritten(self: *Sequencer, value: u8) Step {
        switch (self.state) {
            .idle => {
                if (value == opcode.program) return self.open(.program);
                if (value == opcode.config_set) return self.open(.config_set);
                return .none;
            },
            .opened => {
                self.declared = value;
                self.state = .collecting;
                return .none;
            },
            .collecting => {
                if (value == opcode.final) return .commit;
                self.reset();
                return .abandoned;
            },
        }
    }

    /// One halfword written to the command port. Outside a collecting
    /// stream there is nowhere to put it, which is what dev does too.
    pub fn halfwordWritten(self: *Sequencer, value: u16) void {
        if (self.state != .collecting) return;
        if (self.len + 2 > max_payload) {
            self.overflowed = true;
            return;
        }
        std.mem.writeInt(u16, self.payload[self.len..][0..2], value, .little);
        self.len += 2;
    }

    fn open(self: *Sequencer, kind: Kind) Step {
        self.reset();
        self.kind = kind;
        self.state = .opened;
        return .none;
    }
};
