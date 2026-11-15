//! Wire types for `Method.set_var` (0x013D): mutate a named global or local
//! variable on the stopped core and return an actionable status + message.
const rpc = @import("rpc.zig");

pub const SetVarStatus = enum(u8) {
    ok = 0,
    unknown_variable = 1,
    no_dwarf = 2,
    read_only = 3,
    invalid_value = 4,
    overflow = 5,
    unsupported_type = 6,
    frame_unavailable = 7,
    write_failed = 8,
};

pub const SetVarScope = enum(u8) {
    none = 0,
    global = 1,
    local = 2,
};

pub const SetVarArgs = struct {
    core: rpc.Core,
    frame: u32,
    name: []const u8,
    value: []const u8,

    pub const max_len = .{
        .name = 256,
        .value = 256,
    };
};

pub const SetVarReply = struct {
    status: SetVarStatus,
    scope: SetVarScope,
    address: u32,
    in_register: u8,
    size: u32,
    message: []const u8,

    pub const max_len = .{
        .message = 256,
    };
};
