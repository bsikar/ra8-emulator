//! Project operations are opt-in host services, independent of debugger state.
pub const capability: u32 = 1 << 18;
pub const Method = enum(u16) { open = 0x170, close = 0x171, build = 0x172, prepare = 0x173 };
pub const Open = struct {
    config: []const u8,
    pub const max_len = .{ .config = 4096 };
};
pub const Build = struct {
    recipe: []const u8,
    pub const max_len = .{ .recipe = 64 };
};
pub const Prepared = struct {
    receipt: []const u8,
    pub const max_len = .{ .receipt = 512 };
};
pub const codes = struct {
    pub const unavailable: u16 = 0x170;
    pub const state: u16 = 0x171;
    pub const invalid: u16 = 0x172;
    pub const failed: u16 = 0x173;
    pub const changed: u16 = 0x174;
};
