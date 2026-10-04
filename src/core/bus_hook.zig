//! Unicorn's peripheral-window and invalid-access hooks.
//!
//! src/periph/registry.zig knows what a peripheral read means and nothing
//! about Unicorn; src/core/fault.zig knows what a bad access looks like once
//! it has been recorded. This file is the other half of both: the only place
//! in the emulator besides src/core/c.zig that handles a C calling
//! convention or a raw pointer. Keeping it apart is what lets the bus be tested without a live
//! engine.
const c = @import("c.zig");
const periph = @import("../periph/registry.zig");
const fault = @import("fault.zig");

pub const Error = error{AttachFailed};

/// Put the peripheral registry behind both the secure and non-secure
/// windows. One bus serves both: src/periph/registry.zig folds the
/// non-secure alias onto the secure address before it looks anything up.
pub fn attachBus(handle: ?*c.uc.uc_engine, port: *periph.Port) Error!void {
    inline for (.{ periph.base, periph.ns_base }) |window| {
        if (c.uc.uc_mmio_map(
            handle,
            window,
            periph.size,
            Window(window).onRead,
            port,
            Window(window).onWrite,
            port,
        ) != c.uc.UC_ERR_OK) {
            return Error.AttachFailed;
        }
    }
}

/// Record the invalid accesses a run takes. Without this a fault is just an
/// error code and a PC; with it the report can say which address the
/// firmware reached for and how wide the access was.
pub fn attachWatch(handle: ?*c.uc.uc_engine, watch: *fault.Watch) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_MEM_INVALID,
        @constCast(@as(*const anyopaque, @ptrCast(&onInvalid))),
        watch,
        1,
        0,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

/// Unicorn hands an offset inside the mapped window, so that window's own
/// base is added back before the bus sees it. Adding the Secure base for
/// both windows lost the alias, and the bus could not tell a Non-secure
/// store from a Secure one (RA8EMU-354).
fn Window(comptime window: u32) type {
    return struct {
        fn onRead(uc: ?*c.uc.uc_engine, offset: u64, size: c_uint, user: ?*anyopaque) callconv(.C) u64 {
            _ = uc;
            const port: *periph.Port = @ptrCast(@alignCast(user.?));
            return port.read(window + @as(u32, @truncate(offset)), widthOf(size));
        }

        fn onWrite(uc: ?*c.uc.uc_engine, offset: u64, size: c_uint, value: u64, user: ?*anyopaque) callconv(.C) void {
            _ = uc;
            const port: *periph.Port = @ptrCast(@alignCast(user.?));
            port.write(window + @as(u32, @truncate(offset)), widthOf(size), @truncate(value));
        }
    };
}

fn onInvalid(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) bool {
    _ = uc;
    const watch: *fault.Watch = @ptrCast(@alignCast(user.?));
    watch.last = .{
        .kind = switch (kind) {
            c.uc.UC_MEM_WRITE_UNMAPPED, c.uc.UC_MEM_WRITE_PROT => .write,
            c.uc.UC_MEM_FETCH_UNMAPPED, c.uc.UC_MEM_FETCH_PROT => .fetch,
            else => .read,
        },
        .address = address,
        .size = @intCast(size),
        .value = @bitCast(value),
    };
    // false: do not pretend the access succeeded, let the run stop.
    return false;
}

/// Unicorn reports an access width in bytes; the bus wants the same number
/// in the shape its registers take, with anything unusual read as a word.
pub fn widthOf(size: c_uint) u3 {
    return switch (size) {
        1 => 1,
        2 => 2,
        else => 4,
    };
}
