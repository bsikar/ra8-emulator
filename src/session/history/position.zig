//! A history position on the wire, and the places a position may hold.
//!
//! The position type is the chip scheduler's own; nothing new is invented.
//! This file encodes one little-endian, and refuses the places a round
//! could not have had: an offset past the slots the round actually ran, a
//! CPU1 phase in a cut round, a board gap the atomic board tick never
//! pauses on, and a comparison across two branches, which is OtherLine
//! rather than some arbitrary order between branch numbers.
const std = @import("std");
const scheduler = @import("ra8_chip").core.scheduler;

pub const Position = scheduler.Position;
pub const Phase = scheduler.position.Phase;
pub const Gap = scheduler.position.Gap;

pub const Error = error{ Impossible, OtherLine, Truncated, BadValue };

/// What the round a position names actually ran, straight from the state
/// scheduler's round record. The codec validates against these facts and
/// nothing else; it holds no opinion of its own about rounds.
pub const RoundFacts = struct {
    /// Slots CPU0 ran in the round.
    cpu0: u32 = 0,
    /// Slots CPU1 ran in the round. Zero in a cut round and whenever CPU1
    /// was held.
    cpu1: u32 = 0,
    /// The round was a cut round: CPU1's phase is absent from it entirely.
    cut: bool = false,
};

/// Appends one position to `writer`: branch, r, phase, o, gap.
pub fn encode(writer: anytype, position: Position) !void {
    try writer.writeInt(u32, position.branch, .little);
    try writer.writeInt(u64, position.r, .little);
    try writer.writeByte(@backingInt(position.phase));
    try writer.writeInt(u32, position.o, .little);
    try writer.writeByte(@backingInt(position.gap));
}

/// Reads one position out of `payload` at `*at`, refusing a phase or gap
/// outside its type and a payload that ends inside one.
pub fn decode(payload: []const u8, at: *usize) Error!Position {
    const branch = readInt(u32, payload, at) orelse return Error.Truncated;
    const r = readInt(u64, payload, at) orelse return Error.Truncated;
    const phase_byte = readInt(u8, payload, at) orelse return Error.Truncated;
    const o = readInt(u32, payload, at) orelse return Error.Truncated;
    const gap_byte = readInt(u8, payload, at) orelse return Error.Truncated;
    if (phase_byte > 2 or gap_byte > 1) return Error.BadValue;
    return .{
        .branch = branch,
        .r = r,
        .phase = @fromBackingInt(@intCast(phase_byte)),
        .o = o,
        .gap = @fromBackingInt(@intCast(gap_byte)),
    };
}

/// One little-endian integer, or null when the payload ends inside it.
fn readInt(comptime T: type, payload: []const u8, at: *usize) ?T {
    const span = @sizeOf(T);
    if (payload.len - at.* < span) return null;
    const raw = payload[at.*..][0..span];
    at.* += span;
    return std.mem.readInt(T, raw, .little);
}

/// Whether `position` is a place the round described by `facts` could have
/// had. The board phase is atomic (o 0 or 1, always at its retire gap), a
/// cut round has no CPU1 phase at all, and a CPU phase's offsets stop at
/// the slots it ran, with the phase's own start the one place o may sit at
/// an empty phase.
pub fn validate(position: Position, facts: RoundFacts) Error!void {
    switch (position.phase) {
        .cpu1 => if (facts.cut) return Error.Impossible,
        else => {},
    }
    const slots: u32 = switch (position.phase) {
        .cpu0 => facts.cpu0,
        .cpu1 => facts.cpu1,
        .board => 0,
    };
    switch (position.phase) {
        .cpu0, .cpu1 => {
            const at_start = position.o == 0 and position.gap == .retired;
            if (position.o >= slots and !at_start) return Error.Impossible;
        },
        .board => {
            if (position.o > 1 or position.gap != .retired) return Error.Impossible;
        },
    }
}

/// Orders two positions on one line; across lines there is no order, only
/// the fact that they are different lines.
pub fn compare(a: Position, b: Position) Error!std.math.Order {
    return scheduler.Position.order(a, b) orelse Error.OtherLine;
}
