//! Tests for src/core/systick_hook.zig.
//!
//! The callback itself needs a live engine and is covered by running the
//! images; what is worth pinning here is the window, because a window that
//! took SYST_CVR in would end a boundary on every one of the model's own
//! counter writes.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const mod = ra8.core.systick_hook;

test "the window covers the control word and the reload, and stops there" {
    try std.testing.expectEqual(@as(u64, memmap.syst.csr), mod.window.first);
    try std.testing.expectEqual(@as(u64, memmap.syst.rvr + 3), mod.window.last);
}

test "the counter and the calibration word are outside it" {
    try std.testing.expect(memmap.syst.cvr > mod.window.last);
    try std.testing.expect(memmap.syst.calib > mod.window.last);
}
