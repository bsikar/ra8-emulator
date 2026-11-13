//! Physical pad capabilities shared by RA8P1 and RA8D2. The emulator has no
//! package selector: use the BGA289 non-MIPI GPIO superset (see pads.zig).
//! Reserved ISEL/ASEL bits read zero (HUM 20.2.5). Unsupported PSEL values
//! have unspecified behavior (20.6); retain them rather than invent a refusal.
pub const pads = @import("pads.zig");

pub const field = struct {
    pub const isel: u32 = 1 << 14;
    pub const asel: u32 = 1 << 15;
};

pub const Pad = struct {
    present: bool = false,
    input: bool = false,
    output: bool = false,
    analog: bool = false,
    irq: ?u5 = null,
    functions: u32 = 0,

    pub fn supportsFunction(self: Pad, select: u5) bool {
        return self.functions & (@as(u32, 1) << select) != 0;
    }

    /// Direction enforcement at both PDR write paths belongs to RA8EMU-1253.
    pub fn sanitize(self: Pad, value: u32) u32 {
        if (!self.present) return 0;
        var next = value;
        if (self.irq == null) next &= ~field.isel;
        if (!self.analog) next &= ~field.asel;
        return next;
    }
};

/// Bounds are checked before arithmetic, including callers with large inputs.
pub fn get(port: u32, pin: u32) Pad {
    if (port > 13 or pin > 15) return .{};
    if ((port == 11 or port == 13) and pin > 7) return .{};
    const index = port * 16 + pin - (if (port >= 12) @as(u32, 8) else 0);
    const record = pads.records[index];
    return .{
        .present = true,
        .input = true,
        .output = record.output,
        .analog = record.analog,
        .irq = record.irq,
        .functions = record.functions,
    };
}
