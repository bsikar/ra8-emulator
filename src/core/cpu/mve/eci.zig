//! EPSR.ECI, the beat-wise execution state MVE keeps across an exception
//! (RA8EMU-107), from the Arm ARM (DDI0553) pseudocode. ECI shares the
//! ICI/IT bits: in the IT byte (IT[1:0] at xPSR[26:25], IT[7:2] at
//! [15:10]) a zero low nibble means the high nibble is ECI, the beats of
//! the current instruction (A) and the next (B) already done when the
//! exception was taken. Any other ECI value is reserved and the next
//! beat-wise instruction takes an INVSTATE UsageFault.
pub const Eci = enum(u4) {
    none = 0,
    a0 = 1,
    a0a1 = 2,
    a0a1a2 = 4,
    a0a1a2b0 = 5,
};

/// What the IT byte holds for a beat-wise instruction.
pub const State = union(enum) {
    /// An IT block is open: no beat is skipped.
    it,
    eci: Eci,
    /// A reserved ECI value: INVSTATE.
    reserved,
};

/// Reads the IT byte as IT or ECI state.
pub fn fromIt(it: u8) State {
    if (it & 0xF != 0) return .it;
    return switch (it >> 4) {
        0, 1, 2, 4, 5 => .{ .eci = @enumFromInt(it >> 4) },
        else => .reserved,
    };
}

/// The byte-lane mask of the beats still to run: beat k covers bytes
/// 4k..4k+3, and a completed beat's lanes are clear.
pub fn beatMask(state: State) u16 {
    return switch (state) {
        .it, .reserved => 0xFFFF,
        .eci => |e| switch (e) {
            .none => 0xFFFF,
            .a0 => 0xFFF0,
            .a0a1 => 0xFF00,
            .a0a1a2, .a0a1a2b0 => 0xF000,
        },
    };
}

/// True when the instruction resumes past its first beat.
pub fn skipsFirstBeat(state: State) bool {
    return switch (state) {
        .eci => |e| e != .none,
        else => false,
    };
}

/// The IT byte after a beat-wise instruction finishes: B0 done carries
/// over as A0 of the next instruction, anything else clears. IT state is
/// left to the IT advance.
pub fn next(it: u8) u8 {
    return switch (fromIt(it)) {
        .eci => |e| if (e == .a0a1a2b0) @as(u8, @intFromEnum(Eci.a0)) << 4 else 0,
        else => it,
    };
}
