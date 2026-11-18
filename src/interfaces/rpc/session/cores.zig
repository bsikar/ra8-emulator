//! Answers `Method.list_cores` (RA8EMU-1342) from the session's machine
//! description. A single-core machine lists only slot 0; CPU1 never appears.
const api = @import("ra8_session").api;
const chip = @import("ra8_chip");
const handlers = @import("handlers.zig");
const rpc = @import("ra8_rpc_wire");
const wire = @import("cores_wire.zig");

pub const Outcome = rpc.Outcome(wire.CoreList);

pub fn listCores(context: *handlers.Context, _: struct {}) Outcome {
    const desc = context.session.machine_desc;
    const need = wire.max_items * wire.item_bytes;
    if (context.scratch.len < need) {
        return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.too_long)) };
    }
    const buf = context.scratch[0..need];
    var written: usize = 0;
    inline for (.{
        .{ @as(u8, 0), chip.core.machine.Slot.cpu0, api.Core.cpu0 },
        .{ @as(u8, 1), chip.core.machine.Slot.cpu1, api.Core.cpu1 },
    }) |entry| {
        if (desc.core(entry[1])) |info| {
            wire.put(buf, written, itemOf(entry[0], context.session.hasCore(entry[2]), info));
            written += 1;
        }
    }
    return .{
        .ok = .{
            .machine = desc.name,
            .count = @intCast(written),
            .bytes = buf[0 .. written * wire.item_bytes],
        },
    };
}

/// Whether the session's machine has no core in `which` at all. A present
/// slot whose core is not attached yet (CPU1 before its release on a
/// dual-core part) is not absent: requests that may wait for it keep working.
pub fn absent(session: *const api.Session, which: api.Core) bool {
    return session.machine_desc.core(@fromBackingInt(@intCast(@backingInt(which)))) == null;
}

fn itemOf(slot: u8, attached: bool, info: chip.core.machine.Core) wire.CoreItem {
    var bits: u8 = 0;
    if (info.profile.v8_1m) bits |= wire.flags.v8_1m;
    if (info.mve) bits |= wire.flags.mve;
    if (info.profile.lob) bits |= wire.flags.lob;
    if (info.security) bits |= wire.flags.security;
    var item: wire.CoreItem = .{
        .slot = slot,
        .attached = @intFromBool(attached),
        .cpuid = info.cpuid,
        .flags = bits,
        .fpu = @backingInt(info.fpu),
        .systicks = info.systicks,
        .name_len = @intCast(@min(info.name.len, wire.name_cap)),
    };
    @memcpy(item.name[0..item.name_len], info.name[0..item.name_len]);
    return item;
}
