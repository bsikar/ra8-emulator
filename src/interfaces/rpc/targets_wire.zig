//! Target leases are scoped to the transport connection, never caller-supplied owners.
const model = @import("ra8_host").targets;

pub const capability: u32 = 1 << 21;
// All 32 descriptors fit even when JSON escapes their bounded metadata.
pub const max_json = 256 * 1024;
pub const Method = enum(u16) { list = 0x190, reserve = 0x191, release = 0x192, perform = 0x193 };
pub const Selection = struct {
    host_id: []const u8,
    probe_id: []const u8,
    board_id: []const u8,
    generation: u64,
    disambiguation: []const u8,
    pub const max_len = .{ .host_id = 128, .probe_id = 128, .board_id = 128, .disambiguation = 128 };
};
pub const Perform = struct {
    host_id: []const u8,
    probe_id: []const u8,
    board_id: []const u8,
    generation: u64,
    disambiguation: []const u8,
    action: model.Action,
    pub const max_len = Selection.max_len;
};
pub fn operation(selected: Selection, action: model.Action) Perform {
    return .{
        .host_id = selected.host_id,
        .probe_id = selected.probe_id,
        .board_id = selected.board_id,
        .generation = selected.generation,
        .disambiguation = selected.disambiguation,
        .action = action,
    };
}
pub const Text = struct {
    json: []const u8,
    pub const max_len = .{ .json = max_json };
};
pub const codes = struct {
    pub const unavailable: u16 = 0x190;
    pub const stale: u16 = 0x191;
    pub const ambiguous: u16 = 0x192;
    pub const busy: u16 = 0x193;
    pub const ownership: u16 = 0x194;
    pub const unsupported: u16 = 0x195;
    pub const custodian: u16 = 0x196;
    pub const failed: u16 = 0x197;
};
