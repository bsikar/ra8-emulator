//! Target leases, chunked firmware upload, receipt-bound flashing, and
//! streamed stage events (`progress_topic = 0x183`) scoped strictly to the
//! transport connection, never caller-supplied owners.
const model = @import("ra8_host").targets;

pub const capability: u32 = 1 << 21;
// All 32 descriptors fit even when JSON escapes their bounded metadata.
pub const max_json = 256 * 1024;
pub const max_chunk = 65536;
pub const max_flash_elf: u64 = 4 * 1024 * 1024;
pub const progress_topic: u16 = 0x183;

pub const Method = enum(u16) {
    list = 0x190,
    reserve = 0x191,
    release = 0x192,
    perform = 0x193,
    flash_begin = 0x194,
    flash_chunk = 0x195,
    flash_commit = 0x196,
    flash_receipt = 0x197,
};
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
pub const FlashBegin = struct {
    total_len: u64,
    checksum: u32,
};
pub const FlashChunk = struct {
    offset: u64,
    bytes: []const u8,
    pub const max_len = .{ .bytes = max_chunk };
};
pub const FlashCommit = struct {
    host_id: []const u8,
    probe_id: []const u8,
    board_id: []const u8,
    generation: u64,
    disambiguation: []const u8,
    reset: u8 = 0,
    uart: u8 = 0,
    pub const max_len = Selection.max_len;
};
pub const FlashReceipt = struct {
    host_id: []const u8,
    probe_id: []const u8,
    board_id: []const u8,
    generation: u64,
    disambiguation: []const u8,
    receipt: []const u8,
    reset: u8 = 0,
    uart: u8 = 0,
    pub const max_len = .{
        .host_id = 128,
        .probe_id = 128,
        .board_id = 128,
        .disambiguation = 128,
        .receipt = 512,
    };
};
pub const Progress = struct {
    sequence: u64,
    stage: []const u8,
    json: []const u8,
    pub const max_len = .{ .stage = 64, .json = 4096 };
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
    pub const invalid_artifact: u16 = 0x198;
};
