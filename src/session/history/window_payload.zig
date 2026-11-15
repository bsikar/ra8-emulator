//! Owned byte records and architectural deltas for one reverse-window slot.
const Initiator = @import("ra8_chip").core.cpu.memory.initiator.Initiator;
const slot = @import("window_slot.zig");

const WindowSlot = slot.WindowSlot;
const RegDiff = slot.RegDiff;

pub const ByteSwapRecord = struct {
    base: u32,
    offset: u64,
    part: ?u16,
    initiator: Initiator = .none,
    data: []u8,
};

pub const SlotPayload = struct {
    slot: WindowSlot,
    diffs: []RegDiff,
    byte_records: []ByteSwapRecord,
    micro_bytes: []u8 = &.{},
};
