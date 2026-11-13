//! Workspace RPC contract. All paths are relative to the configured root.
const host = @import("ra8_host").workspace;
pub const capability: u32 = 1 << 16;
pub const changed_topic: u16 = 0x0180;
pub const Version = host.Version;
pub const version_bytes = 25;
pub fn encodeVersion(version: Version, into: []u8) ![]const u8 {
    return @import("ra8_rpc_wire").codec.encode(Version, version, into);
}
pub fn decodeVersion(bytes: []const u8) !Version {
    return @import("ra8_rpc_wire").codec.decode(Version, bytes);
}
pub const Method = enum(u16) { list = 0x0140, stat = 0x0141, read = 0x0142, write = 0x0143, watch = 0x0144, unwatch = 0x0145 };
pub const Path = struct {
    path: []const u8,
    pub const max_len = .{ .path = host.path.capacity };
};
pub const List = struct {
    path: []const u8,
    offset: u32,
    limit: u16,
    pub const max_len = .{ .path = host.path.capacity };
};
/// Entries are JSON name/kind objects; directory order is unspecified.
pub const Page = struct {
    offset: u32,
    count: u16,
    more: u8,
    entries: []const u8,
    pub const max_len = .{ .entries = 65_536 };
};
pub const Read = struct {
    path: []const u8,
    offset: u64,
    length: u32,
    pub const max_len = .{ .path = host.path.capacity };
};
pub const Contents = struct {
    version: []const u8,
    eof: u8,
    bytes: []const u8,
    pub const max_len = .{ .version = version_bytes, .bytes = host.max_file_bytes };
};
/// A missing version creates exclusively; no unconditional overwrite.
pub const Write = struct {
    path: []const u8,
    expected: []const u8,
    bytes: []const u8,
    pub const max_len = .{ .path = host.path.capacity, .expected = version_bytes, .bytes = host.max_file_bytes };
};
pub const Watch = struct { id: u32 };
pub const Change = struct {
    id: u32,
    state: State,
    path: []const u8,
    version: []const u8,
    pub const max_len = .{ .path = host.path.capacity, .version = version_bytes };
};
pub const State = enum(u8) { changed, removed, unavailable };
pub const codes = struct {
    pub const unavailable: u16 = 0x0150;
    pub const invalid_path: u16 = 0x0151;
    pub const conflict: u16 = 0x0152;
    pub const too_large: u16 = 0x0153;
    pub const not_found: u16 = 0x0154;
    pub const invalid_watch: u16 = 0x0155;
    pub const io: u16 = 0x0156;
    pub const not_file: u16 = 0x0157;
};
