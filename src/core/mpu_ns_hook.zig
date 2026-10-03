//! Unicorn's memory-write hook over the MPU_NS alias (RA8EMU-445).
//!
//! The MPU is banked whole between the Security states (DDI0553A.k B3.5),
//! and Secure code reaches the Non-secure MPU through the alias at
//! 0xE002_ED90..0xE002_EDC7. The Zig bus files those stores into the
//! board's Non-secure table (src/periph/mpu/mpu_ns.zig); this hook does the
//! same on the Unicorn backend, so a Secure boot that programs both MPUs
//! keeps two tables rather than piling the Non-secure regions into RAM.
//!
//! ONLY THE ALIAS, NOT THE NORMAL WINDOW FROM NON-SECURE CODE. The Unicorn
//! backend carries no Security state: its CPU model is never told when the
//! firmware crosses into Non-secure code (no banked SP, CONTROL or state
//! register reaches this side of the engine), so a store to 0xE000_ED90 from
//! Non-secure code looks exactly like one from Secure code and still lands
//! in the Secure table through src/core/mpu_hook.zig. The addresses are what
//! this backend can tell apart, so that is what it banks by. Nothing
//! enforces the Non-secure table here either: with no state to say when
//! Non-secure code runs, there is no access to judge by it.
const c = @import("c.zig");
const memmap = @import("memmap.zig");
const mpu = @import("../periph/mpu/mpu.zig");
const mpu_ns = @import("../periph/mpu/mpu_ns.zig");

pub const Error = error{AttachFailed};

/// The alias window the hook watches: TYPE through MAIR1, inclusive.
pub const window = struct {
    pub const first: u64 = memmap.mpu.type_ + mpu_ns.offset;
    pub const last: u64 = memmap.mpu.mair1 + 3 + mpu_ns.offset;
};

/// One word the hook puts back in front of the firmware.
pub const Word = struct { address: u32, value: u32 };

pub fn attach(handle: ?*c.uc.uc_engine, unit: *mpu.Mpu) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_MEM_WRITE,
        @constCast(@as(*const anyopaque, @ptrCast(&onWrite))),
        unit,
        window.first,
        window.last,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

/// File a word store at alias `address` into the Non-secure table. True
/// when RNR moved, so the selected pairs need putting back. A store that is
/// not to an MPU register through the alias files nothing.
pub fn file(unit: *mpu.Mpu, address: u32, value: u32) bool {
    const normal = mpu_ns.normalOf(address) orelse return false;
    return unit.observe(normal, value) == .rebank;
}

/// The eight alias words RNR now selects in the Non-secure table: RBAR and
/// RLAR, then the three A1..A3 pairs.
pub fn selected(unit: *const mpu.Mpu) [8]Word {
    const pairs = [_][2]u32{
        .{ memmap.mpu.rbar, memmap.mpu.rlar },
        .{ memmap.mpu.rbar_a1, memmap.mpu.rlar_a1 },
        .{ memmap.mpu.rbar_a2, memmap.mpu.rlar_a2 },
        .{ memmap.mpu.rbar_a3, memmap.mpu.rlar_a3 },
    };
    var out: [8]Word = undefined;
    for (pairs, 0..) |where, offset| {
        const words = unit.pairFor(@intCast(offset));
        out[2 * offset] = .{ .address = where[0] + mpu_ns.offset, .value = words[0] };
        out[2 * offset + 1] = .{ .address = where[1] + mpu_ns.offset, .value = words[1] };
    }
    return out;
}

fn onWrite(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = kind;
    // Word registers written as words, as in src/core/mpu_hook.zig.
    if (size != 4) return;
    const unit: *mpu.Mpu = @ptrCast(@alignCast(user.?));
    const word: u32 = @bitCast(@as(i32, @truncate(value)));
    if (!file(unit, @truncate(address), word)) return;
    for (selected(unit)) |put| {
        var bytes = put.value;
        _ = c.uc.uc_mem_write(uc, put.address, &bytes, @sizeOf(u32));
    }
}
