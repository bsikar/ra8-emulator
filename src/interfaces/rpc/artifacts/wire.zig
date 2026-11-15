//! Artifact transfers use connection-owned IDs and bounded chunks, never host paths.
//! Enable with serve --artifacts-root; non-loopback listeners also need --allow-state-files.
//! Begin returns an ID, total length and SHA256. Read/write offsets must advance in order.
//! Export is frozen at begin; abort or disconnect releases its spool. Failed uploads are discarded.
//! Import-end acknowledges a validated replacement, then socket clients reconnect to the same listener.
//! Recording bundles include their ELFs/profile; state-only imports reuse the active session's images.
//! Host device bindings and client subscriptions are not portable bundle contents.
pub const capability: u32 = 1 << 20;
pub const max_chunk = 65536;
pub const max_bundle: u64 = 4 * 1024 * 1024 * 1024;

pub const Method = enum(u16) {
    export_begin = 0x180,
    export_read = 0x181,
    import_begin = 0x182,
    import_write = 0x183,
    import_end = 0x184,
    abort = 0x185,
};
pub const Export = struct { recording: u8 };
pub const Descriptor = struct {
    id: u64,
    total: u64,
    sha256: []const u8,
    pub const max_len = .{ .sha256 = 32 };
};
pub const Begin = struct {
    total: u64,
    sha256: []const u8,
    pub const max_len = .{ .sha256 = 32 };
};
pub const Id = struct { id: u64 };
pub const Read = struct { id: u64, offset: u64, length: u32 };
pub const Chunk = struct {
    id: u64,
    offset: u64,
    bytes: []const u8,
    pub const max_len = .{ .bytes = max_chunk };
};
pub const Commit = struct { accepted: u8, reconnect: u8 };
pub const codes = struct {
    pub const unavailable: u16 = 0x180;
    pub const state: u16 = 0x181;
    pub const invalid: u16 = 0x182;
    pub const too_large: u16 = 0x183;
    pub const io: u16 = 0x184;
};
