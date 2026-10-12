//! The widget abi's link set, checked where SDL cannot (RA8EMU-1176).
//!
//! The gui test binaries (tests/interfaces/gui/sdl/geometry_test.zig and the
//! ra8_gui smoke run) need SDL3, and the CI box has none, so a link break in
//! them rode into a PR as RA8EMU-1173: after RA8EMU-1159 moved the widget
//! host behind ra8_render's internal package, nothing in that binary's import
//! graph referenced widget_paint, so its exports were never analyzed and the
//! link failed with five undefined widget symbols. This binary checks the
//! same guarantee headlessly: a consumer that imports only the umbrella and
//! the widget library links, so the widget abi's externs must resolve through
//! what the umbrella carries, never through a test that happens to reference
//! widget_paint.
const std = @import("std");
const ra8 = @import("ra8");
const widget = @import("ra8_widget");

test "the widget abi's externs resolve through the umbrella alone" {
    // Resolving the render library runs the comptime block that carries the
    // widget abi's externs (RA8EMU-1173). The widget library's own code calls
    // them, so if that block stops riding on the umbrella, this link fails
    // here, where the gui test binaries' SDL link never runs.
    _ = ra8.render;
    refAll(widget);
}

/// References every declaration in `T` and descends into the types it
/// declares, so the analyzer sees and emits the callers.
fn refAll(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => {},
        else => return,
    }
    inline for (comptime std.meta.declarations(T)) |decl| {
        const d = @field(T, decl);
        if (@TypeOf(d) == type) refAll(d);
        _ = &d;
    }
}
