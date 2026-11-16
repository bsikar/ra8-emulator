//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie

const std = @import("std");
const image = @import("image_build.zig");

const firmware = "ra8-firmware/";

/// The firmware modules the UI is built from, for one target.
const Firmware = struct {
    widget: *std.Build.Module,
    canvas: *std.Build.Module,
    box: *std.Build.Module,
    ui_rect: *std.Build.Module,
    debug: *std.Build.Module,

    fn module(b: *std.Build, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        return b.createModule(.{ .root_source_file = b.path(b.fmt("{s}{s}", .{ firmware, path })), .target = target, .optimize = optimize });
    }

    fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Firmware {
        const text = module(b, "libs/ra8_gfx/src/internal/text.zig", target, optimize);
        const debug = module(b, "libs/ra8_widget/src/widget_debug_abi.zig", target, optimize);
        const widget = module(b, "libs/ra8_widget/src/ra8_widget_abi.zig", target, optimize);
        if (optimize == .Debug) widget.addImport("debug", debug);
        const canvas = module(b, "libs/ra8_widget/src/host_paint.zig", target, optimize);
        canvas.addImport("text", text);
        return .{
            .widget = widget,
            .canvas = canvas,
            .box = module(b, "libs/ra8_box/src/ra8_box_abi.zig", target, optimize),
            .ui_rect = module(b, "libs/ra8_ui/src/ra8_ui_abi.zig", target, optimize),
            .debug = debug,
        };
    }
};

/// The UI itself, as a module over the firmware's widget library.
fn uiModule(b: *std.Build, fw: Firmware, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const ui = b.createModule(.{ .root_source_file = b.path("app/root.zig"), .target = target, .optimize = optimize });
    ui.addImport("ra8_widget", fw.widget);
    ui.addImport("canvas", fw.canvas);
    if (optimize == .Debug) ui.addImport("widget_debug", fw.debug);
    return ui;
}

pub fn build(b: *std.Build) void {
    // The board image: the same UI module, for the Cortex-M85, with the
    // board entry as its root.
    const board_target = image.target(b);
    const board_fw = Firmware.init(b, board_target.resolved, board_target.optimize);
    const main = b.createModule(.{
        .root_source_file = b.path("board/src/main.zig"),
        .target = board_target.resolved,
        .optimize = board_target.optimize,
        .unwind_tables = .none,
    });
    main.addImport("ui", uiModule(b, board_fw, board_target.resolved, board_target.optimize));
    main.addImport("ra8_box", board_fw.box);
    main.addImport("ra8_ui_rect", board_fw.ui_rect);
    const main_object = b.addObject(.{ .name = image.name ++ "_main", .root_module = main });
    const image_step = b.step("image", "Build the UI firmware image");
    image.add(b, image_step, b.dependency("ra8_firmware", .{}), main_object.getEmittedBin(), board_target);
}
