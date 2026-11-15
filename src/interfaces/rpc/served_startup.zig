const served_card = @import("served_card.zig");

/// Borrowed startup input; CPU1 copies bytes before openInitial returns.
pub const Startup = struct {
    card: served_card.Options = .{},
    /// A complete SD snapshot read from an admitted immutable replay root.
    media: ?[]const u8 = null,
};
