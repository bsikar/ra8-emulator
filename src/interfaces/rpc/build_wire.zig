//! Backend build contract. Result and diagnostic JSON are version-one records.
pub const capability: u32 = 1 << 17;
pub const event_topic: u16 = 0x181;
pub const completed_topic: u16 = 0x182;
pub const Method = enum(u16) { start = 0x160, status = 0x161, cancel = 0x162 };
pub const Start = struct {
    step: []const u8,
    options: []const u8,
    artifact: []const u8,
    timeout_ms: u32,
    pub const max_len = .{ .step = 64, .options = 4096, .artifact = 512 };
};
pub const Id = struct { id: u64 };
pub const Status = struct {
    id: u64,
    done: u8,
    result: []const u8,
    pub const max_len = .{ .result = 32_768 };
};
pub const Event = struct {
    id: u64,
    sequence: u64,
    kind: @import("ra8_host").build.queue.Kind,
    bytes: []const u8,
    pub const max_len = .{ .bytes = 4096 };
};
pub const codes = struct {
    pub const unavailable: u16 = 0x160;
    pub const busy: u16 = 0x161;
    pub const unknown_job: u16 = 0x162;
    pub const io: u16 = 0x163;
};
